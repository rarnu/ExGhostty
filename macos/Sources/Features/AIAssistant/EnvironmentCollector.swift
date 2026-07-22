import Foundation
import os

/// 终端环境信息采集器。
///
/// 根据终端类型（本地 / SSH 远程）在对应环境中采集系统基础信息、
/// Git 上下文、开发工具版本及关键环境标记，供 AI 助手构建 system prompt。
///
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
                if cleaned.isEmpty {
                    return formatOutput("", cwd: cwd, hostType: "Local environment")
                }
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
                if cleaned.isEmpty {
                    return formatOutput(
                        "",
                        cwd: cwd,
                        hostType: "Remote environment (SSH: \(connection.username)@\(connection.host))"
                    )
                }
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

    /// 过滤掉文本中的 `<think>...</think>` 块。
    ///
    /// 某些远端服务器配置了 AI shell 插件（如通义灵码等），
    /// 会在 shell 输出中混入思考内容，需要剥离。
    private static func stripThinkBlocks(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var result = text
        while let start = result.range(of: "<think>"),
              let end = result.range(of: "</think>") {
            if start.lowerBound < end.lowerBound {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                break
            }
        }
        if let start = result.range(of: "<think>") {
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
    /// 每项独立采集，未安装 / 不存在的工具静默不输出。
    /// 磁盘取前 5 个 `/dev/` 真实分区，GPU 搜索 nvidia-smi 路径，
    /// conda 搜索常见安装位置。
    private static let probeScript = """
(
# ============================================================
# T1: System & Hardware
# ============================================================
echo "OS: $(uname -s) $(uname -r) $(uname -m)"

[ -f /etc/os-release ] && . /etc/os-release 2>/dev/null
[ -n "$PRETTY_NAME" ] && echo "Distro: $PRETTY_NAME"

echo "Shell: ${SHELL:-unknown}"

echo "Hostname: $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"

echo "CPU cores: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown)"

free -m 2>/dev/null | awk '/^Mem:/{printf "Memory: %.0fG total %.0fG used (%.0f%%)\\n", $2/1024, $3/1024, ($3*100/$2)}'

# Disk: top 5 /dev/ real partitions
df -h 2>/dev/null | awk '/^\\/dev\\//{print $2,$3,$5,$NF}' | sort -t'/' -k2 | head -5 | while read total used pct mount; do
    echo "Disk $mount: $used/$total ($pct)"
done

# GPU: search nvidia-smi in PATH and common locations
smipath=$(command -v nvidia-smi 2>/dev/null)
if [ -z "$smipath" ]; then
    for p in /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi /opt/nvidia/bin/nvidia-smi; do
        [ -x "$p" ] && { smipath="$p"; break; }
    done
fi
if [ -n "$smipath" ]; then
    "$smipath" --query-gpu=name,memory.total,memory.used,temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | awk -F', *' '{printf "GPU %s: used %s/%s temp %s\\n", $1, $3, $2, $4}'
fi

# Network: top 4 active interfaces (skip lo)
awk 'NR>2 && $2>0 {
    split($1,a,":"); name=a[1]
    if(name!="lo") printf "Network %s: rx=%.0fGB tx=%.0fGB\\n", name, $2/1073741824, $10/1073741824
}' /proc/net/dev 2>/dev/null | head -4

# Load
awk '{printf "Load: %s %s %s\\n", $1, $2, $3}' /proc/loadavg 2>/dev/null

# ============================================================
# T2: Git Context (only inside a git repo)
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
# T3: Dev Tools (only installed ones)
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
# T4: Environment Markers
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
