import Foundation
import os

/// 终端环境信息采集器。
///
/// 根据终端类型（本地 / SSH 远程）在对应环境中采集：
/// - 操作系统身份信息（OS family / macOS 版本 / 架构 / Homebrew）
/// - xtop 一次性系统资源快照（CPU / 内存 / 磁盘 / GPU / 网络 / 进程，
///   直接输出 `xtop --all --json` 原始 JSON，不做解析；未安装则跳过）
/// - Git 上下文、开发工具版本及关键环境标记
///
/// 供 AI 助手构建 system prompt（纯文本直传，不解析）。
///
/// 注意：`probeScript` 是 internal（而非 private），
/// 以便单元测试断言脚本的静态不变量。
/// 采集结果带 TTL 缓存（5分钟），避免每次发送消息都重复探测。
///
/// 设计原则：
/// - 逐项独立：每项采集互不依赖，一项失败不影响其他
/// - 能取什么就返回什么：未安装的工具不出现，失败的命令静默跳过
/// - 纯文本直传：不使用 base64/管道，直接作为命令发送
/// - 必须 exit 0：避免 ProcessRunner 因退出码抛异常
enum EnvironmentCollector {

    // MARK: - 缓存

    private struct CacheEntry {
        let text: String
        let timestamp: Date
    }

    private static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 300

    // MARK: - 公开接口

    /// 采集本地环境信息。
    static func collectLocal(cwd: String?) async -> String {
        await cachedOrCollect(key: "local") {
            do {
                let output = try await ProcessRunner.run(
                    shellCommand: probeScript,
                    loginShell: true
                )
                let cleaned = stripThinkBlocks(output)
                return formatOutput(cleaned, cwd: cwd, hostType: "Local environment")
            } catch {
                // 有 exit 0 守卫，理论上不会到这里；保卫性兜底
                return formatOutput("", cwd: cwd, hostType: "Local environment")
            }
        }
    }

    /// 通过 SSH 采集远程服务器环境信息。
    static func collectRemote(
        connection: SSHConnection,
        cwd: String?
    ) async -> String {
        let key = "ssh-\(connection.id.uuidString)"
        return await cachedOrCollect(key: key) {
            do {
                // 纯文本直传，不用 base64
                let output = try await SSHCommandExecutor.shared.execute(
                    remoteCommand: probeScript,
                    connection: connection
                )
                let cleaned = stripThinkBlocks(output)
                return formatOutput(
                    cleaned,
                    cwd: cwd,
                    hostType: "Remote environment (SSH: \(connection.username)@\(connection.host))"
                )
            } catch {
                var fallback = "Remote environment: \(connection.username)@\(connection.host)"
                fallback += "\nEnv probe unavailable: \(error.localizedDescription)"
                return fallback
            }
        }
    }

    // MARK: - 内部辅助

    private static func formatOutput(
        _ probeOutput: String,
        cwd: String?,
        hostType: String
    ) -> String {
        var lines: [String] = [hostType]
        if let cwd, !cwd.isEmpty {
            lines.append("Current directory: \(cwd)")
        }
        let trimmed = probeOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }

    private static func cachedOrCollect(
        key: String,
        collect: () async -> String
    ) async -> String {
        if let entry = cache[key],
           Date().timeIntervalSince(entry.timestamp) < cacheTTL {
            return entry.text
        }
        let result = await collect()
        cache[key] = CacheEntry(text: result, timestamp: Date())
        pruneStaleEntries()
        return result
    }

    private static func pruneStaleEntries() {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.timestamp) < cacheTTL }
    }

    /// 过滤掉文本中的 AI 思考块（某些 AI shell 插件会混入思考内容）。
    ///
    /// 标签以字符串拼接构造，避免字面量形式被代码处理工具误转义。
    internal static func stripThinkBlocks(_ text: String) -> String {
        let openTag = "<" + "think"
        let closeTag = "</" + "think" + ">"
        guard text.contains(openTag) else { return text }
        var result = text
        while let start = result.range(of: openTag),
              let end = result.range(of: closeTag) {
            if start.lowerBound < end.lowerBound {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                break
            }
        }
        if let start = result.range(of: openTag) {
            result.removeSubrange(start.lowerBound...)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 探测脚本

    /// 环境探测脚本（POSIX 兼容）。
    ///
    /// 整体包裹在 `( ... ) || true` 子 shell 内，
    /// 末尾 `exit 0`，确保永远以退出码 0 结束。
    ///
    /// 采集内容：
    /// - OS 身份（uname / OS family / sw_vers / 架构 / Homebrew / Shell /
    ///   主机名）—— xtop 不提供这些，必须自己取
    /// - xtop 一次性快照：`xtop --all --json` 原始 JSON 直传，不解析
    ///   （xtop 是本项目系统监控面板的同一数据源；未安装则整段跳过，
    ///   不带 --stream 时单次输出即退出，不会挂起）
    /// - Git 上下文、开发工具版本、关键环境变量
    ///
    /// internal（而非 private）以便单元测试断言脚本的静态不变量。
    static let probeScript = """
(
# ============================================================
# T1: OS identity (xtop 不提供，单独采集)
# ============================================================
echo "OS: $(uname -s) $(uname -r) $(uname -m)"

# Explicit OS family so the AI never confuses macOS with Linux
case "$(uname -s)" in
    Darwin)
        echo "OS family: macOS"
        sw_vers 2>/dev/null | awk -F' *=' '/ProductVersion/{printf "macOS version: %s\\n", $2}'
        [ "$(uname -m)" = "arm64" ] && echo "CPU arch: Apple Silicon (arm64)" || echo "CPU arch: Intel (x86_64)"
        command -v brew >/dev/null 2>&1 && echo "Brew: $(brew --version 2>/dev/null | head -1)"
        ;;
    Linux)
        echo "OS family: Linux"
        [ -f /etc/os-release ] && . /etc/os-release 2>/dev/null
        [ -n "$PRETTY_NAME" ] && echo "Distro: $PRETTY_NAME"
        ;;
    *)
        echo "OS family: $(uname -s)"
        ;;
esac

echo "Shell: ${SHELL:-unknown}"

echo "Hostname: $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"

# ============================================================
# T2: xtop system resource snapshot (raw JSON, skip if absent)
# ============================================================
xtopbin=$(command -v xtop 2>/dev/null)
if [ -n "$xtopbin" ] && [ -x "$xtopbin" ]; then
    # 不带 --stream：单次输出后即退出，不会挂起。
    # 原始 JSON 直传给 AI，不做解析；GPU 进程列表等体积大的字段
    # 由 AI 按需阅读（context 有 5 分钟 TTL 缓存，不会每次请求都重采）。
    "$xtopbin" --all --json 2>/dev/null
fi

# ============================================================
# T3: Git Context (only inside a git repo)
# ============================================================
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Git branch: $(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)"
    echo "Git remote: $(git remote get-url origin 2>/dev/null || echo none)"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        echo "Git status: dirty"
    else
        echo "Git status: clean"
    fi
fi

# ============================================================
# T4: Dev Tools (only installed ones)
# ============================================================
command -v python3 >/dev/null 2>&1 && echo "Python: $(python3 --version 2>&1 | head -1)"
command -v node >/dev/null 2>&1 && echo "Node: $(node --version 2>&1)"
command -v go >/dev/null 2>&1 && echo "Go: $(go version 2>&1 | head -1)"
command -v java >/dev/null 2>&1 && echo "Java: $(java -version 2>&1 | head -1)"
command -v rustc >/dev/null 2>&1 && echo "Rust: $(rustc --version 2>&1)"
command -v docker >/dev/null 2>&1 && echo "Docker: $(docker --version 2>&1)"
command -v kubectl >/dev/null 2>&1 && echo "kubectl: $(kubectl version --client 2>/dev/null | head -1)"
command -v npm >/dev/null 2>&1 && echo "npm: $(npm --version 2>&1)"
command -v git >/dev/null 2>&1 && echo "Git: $(git --version 2>&1)"

# ============================================================
# T5: Environment Markers
# ============================================================
[ -n "$VIRTUAL_ENV" ] && echo "VIRTUAL_ENV: $VIRTUAL_ENV"
[ -n "$CONDA_DEFAULT_ENV" ] && echo "CONDA_DEFAULT_ENV: $CONDA_DEFAULT_ENV"
[ -n "$GOPATH" ] && echo "GOPATH: $GOPATH"
[ -n "$JAVA_HOME" ] && echo "JAVA_HOME: $JAVA_HOME"
[ -n "$NVM_DIR" ] && echo "NVM_DIR: $NVM_DIR"

# Conda: search PATH then common install locations
condaexe=$(command -v conda 2>/dev/null)
if [ -z "$condaexe" ]; then
    for p in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" /opt/conda/bin/conda; do
        [ -x "$p" ] && { condaexe="$p"; break; }
    done
fi
if [ -n "$condaexe" ] && [ -x "$condaexe" ]; then
    echo "Conda: $("$condaexe" --version 2>&1 | head -1)"
    envlist=$("$condaexe" env list 2>/dev/null | awk 'NR>2 && $1 !~ /^#/ { print $1 }' | head -5 | paste -sd, - 2>/dev/null)
    [ -n "$envlist" ] && echo "Conda envs: $envlist"
fi

) || true
exit 0
"""
}