//
//  AIAssistantViewModel.swift
//  ExGhostty_iPad
//
//  View model for the AI assistant panel: manages the current
//  conversation, streams replies through AIAssistantService, collects
//  the remote server environment (cached 5 minutes) as system prompt,
//  and forwards AI-generated commands to the terminal.
//

import Foundation
import Combine
import UIKit

@MainActor
final class AIAssistantViewModel: ObservableObject {

    @Published var conversation: AIConversation
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var statusText: String?
    @Published var errorMessage: String?
    @Published var showHistory: Bool = false

    private let session: SSHSession
    private weak var terminalBox: TerminalBox?

    private var streamTask: Task<Void, Never>?

    // MARK: - 环境信息缓存（5 分钟 TTL，按会话缓存）

    private struct ContextCacheEntry {
        let text: String
        let timestamp: Date
    }

    private static var contextCache: [ObjectIdentifier: ContextCacheEntry] = [:]
    private static let contextTTL: TimeInterval = 300

    init(session: SSHSession, terminalBox: TerminalBox) {
        self.session = session
        self.terminalBox = terminalBox
        self.conversation = AIConversation()
    }

    /// 面板消失时停止流式任务并落盘历史。
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
        statusText = nil
        AIAssistantHistoryStore.shared.flush()
    }

    // MARK: - 发送消息

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputText = ""
        errorMessage = nil

        conversation.messages.append(AIMessage(role: .user, content: text))
        if conversation.title == "新对话" {
            conversation.title = String(text.prefix(20))
        }
        conversation.updatedAt = Date()
        persist()

        startStream()
    }

    /// 发送失败后重试（基于现有消息重新请求一次）。
    func retry() {
        guard !isSending,
              conversation.messages.contains(where: { $0.role == .user }) else { return }
        errorMessage = nil
        startStream()
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        statusText = nil
        isSending = false
    }

    private func startStream() {
        isSending = true
        statusText = "正在采集服务器环境信息…"

        let assistantMessage = AIMessage(role: .assistant, content: "")
        conversation.messages.append(assistantMessage)
        let assistantID = assistantMessage.id

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }

            let context = await self.environmentContext()
            guard !Task.isCancelled else { return }

            if self.assistantContent(id: assistantID).isEmpty {
                self.statusText = "正在等待 AI 回复…"
            }

            let history = self.conversation.messages.filter { $0.id != assistantID }

            do {
                let result = try await AIAssistantService.streamReply(
                    messages: history,
                    systemContext: context
                ) { [weak self] partial in
                    guard let self else { return }
                    self.updateAssistant(id: assistantID, content: partial)
                    if !partial.isEmpty {
                        self.statusText = nil
                    }
                }

                self.updateAssistant(id: assistantID, content: result)
                self.conversation.updatedAt = Date()
                self.persist()
            } catch is CancellationError {
                // 用户取消，不报错；保留已接收的部分内容。
                self.persist()
            } catch {
                self.errorMessage = error.localizedDescription
                // 移除未完成的助手占位消息。
                if let index = self.conversation.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.conversation.messages.remove(at: index)
                }
                self.persist()
            }

            self.statusText = nil
            self.isSending = false
        }
    }

    private func assistantContent(id: UUID) -> String {
        conversation.messages.first(where: { $0.id == id })?.content ?? ""
    }

    private func updateAssistant(id: UUID, content: String) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        conversation.messages[index].content = content
    }

    // MARK: - 远程环境采集

    /// 通过 SSH exec 在远端执行环境采集脚本，结果缓存 5 分钟。
    private func environmentContext() async -> String {
        let key = ObjectIdentifier(session)
        if let entry = Self.contextCache[key],
           Date().timeIntervalSince(entry.timestamp) < Self.contextTTL {
            return entry.text
        }

        do {
            let result = try await session.exec(Self.probeScript)
            let text = Self.stripThinkBlocks(result.stdout)
            let context = text.isEmpty ? "（环境信息采集无输出）" : text
            Self.contextCache[key] = ContextCacheEntry(text: context, timestamp: Date())
            return context
        } catch {
            // 采集失败不缓存，下次发送时重试。
            return "（环境信息采集失败：\(error.localizedDescription)）"
        }
    }

    /// 过滤掉文本中的 AI 思考块（某些远端服务器配置了 AI shell 插件，
    /// 会在 shell 输出中混入思考内容，需要剥离）。
    /// 标签以字符串拼接构造，避免字面量形式被代码处理工具误转义。
    /// 与 Mac 版 EnvironmentCollector.stripThinkBlocks 一致。
    static func stripThinkBlocks(_ text: String) -> String {
        let openTag = "<" + "think"
        let closeTag = "</" + "think" + ">"
        guard text.contains(openTag) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    /// 环境探测脚本（POSIX 兼容），整体保证以退出码 0 结束。
    /// 与 Mac 版 EnvironmentCollector.probeScript 保持一致：
    /// - T1: OS 身份（uname / OS family / sw_vers / 架构 / Brew / Shell / 主机名）
    /// - T2: xtop 一次性资源快照（`xtop --all --json` 原始 JSON 直传，
    ///   不解析；不带 --stream 单次输出即退出；未安装则整段跳过）
    /// - T3/T4/T5: Git 上下文、开发工具版本、关键环境变量
    private static let probeScript = """
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

    // MARK: - 终端 / 剪贴板

    /// 把 AI 生成的命令发送到当前终端并回车执行。
    func sendToTerminal(_ command: String) {
        guard let terminalView = terminalBox?.terminalView else { return }
        terminalView.sendText(command)
        terminalView.sendText("\r")
    }

    /// 复制文本到剪贴板。
    func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    // MARK: - 会话管理

    /// 新建对话。当前对话有内容时先存入历史。
    func newConversation() {
        cancel()
        errorMessage = nil
        showHistory = false

        if !conversation.messages.isEmpty {
            AIAssistantHistoryStore.shared.save(conversation)
        }
        conversation = AIConversation()
    }

    /// 切换到历史中的一条对话。当前对话有内容时先保存。
    func selectConversation(_ target: AIConversation) {
        cancel()
        errorMessage = nil
        showHistory = false

        if !conversation.messages.isEmpty {
            AIAssistantHistoryStore.shared.save(conversation)
        }

        if let fresh = AIAssistantHistoryStore.shared.conversation(id: target.id) {
            conversation = fresh
        } else {
            conversation = target
        }
    }

    /// 删除一条历史对话；若删除的是当前对话则新建一条空对话。
    func deleteConversation(id: UUID) {
        AIAssistantHistoryStore.shared.delete(id: id)
        if conversation.id == id {
            cancel()
            errorMessage = nil
            conversation = AIConversation()
        }
    }

    private func persist() {
        guard !conversation.messages.isEmpty else { return }
        AIAssistantHistoryStore.shared.save(conversation)
    }
}
