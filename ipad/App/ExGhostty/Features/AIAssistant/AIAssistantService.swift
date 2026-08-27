//
//  AIAssistantService.swift
//  ExGhostty_iPad
//
//  OpenAI-compatible streaming chat service for the AI assistant panel.
//  Reads endpoint / apiKey / model from SettingsStore, posts to
//  {endpoint}/chat/completions with stream=true, and parses the SSE
//  response line by line, filtering out <think>...</think> blocks.
//

import Foundation

/// AI 对话中的消息角色。
enum AIMessageRole: String, Codable {
    case system
    case user
    case assistant
}

/// AI 对话中的一条消息。
struct AIMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: AIMessageRole
    var content: String
    var timestamp: Date

    init(
        id: UUID = UUID(),
        role: AIMessageRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// 一段完整的 AI 对话（历史记录单元）。
struct AIConversation: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var messages: [AIMessage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        messages: [AIMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 列表展示标题：取第一条用户消息的前 20 个字符，为空则用默认标题。
    var displayTitle: String {
        if let firstUser = messages.first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            let prefix = String(firstUser.prefix(20))
            return firstUser.count > 20 ? prefix + "…" : prefix
        }
        return title.isEmpty ? "新对话" : title
    }
}

/// AI 服务错误。
enum AIAssistantError: LocalizedError {
    case configurationMissing
    case invalidEndpoint
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "AI 服务未配置，请先在设置页填写 API Key。"
        case .invalidEndpoint:
            return "AI 接口地址无效。"
        case .invalidResponse:
            return "AI 服务返回了无效的响应。"
        case .httpError(let statusCode, let message):
            return L("AI 请求失败（%d）：%@", statusCode, message)
        }
    }
}

/// 与兼容 OpenAI 的 AI 接口通信并流式接收应答。
@MainActor
enum AIAssistantService {

    /// 当前是否已完成配置（endpoint / apiKey / model 均非空）。
    static var isConfigured: Bool {
        let settings = SettingsStore.shared
        return !settings.aiEndpoint.isEmpty
            && !settings.aiAPIKey.isEmpty
            && !settings.aiModel.isEmpty
    }

    /// 发送消息并流式返回 AI 应答。
    /// - Parameters:
    ///   - messages: 历史消息列表，会一并作为上下文发送。
    ///   - systemContext: 远程服务器环境信息，作为 system prompt 的一部分。
    ///   - onUpdate: 每收到一段流式内容即回调一次（参数为目前已累积的完整可见文本）。
    /// - Returns: 完整的 AI 应答文本（已过滤 thinking 内容）。
    static func streamReply(
        messages: [AIMessage],
        systemContext: String,
        onUpdate: @escaping (String) -> Void
    ) async throws -> String {
        let settings = SettingsStore.shared
        guard isConfigured else {
            throw AIAssistantError.configurationMissing
        }
        guard let url = URL(string: settings.aiEndpoint)?
            .appendingPathComponent("chat/completions") else {
            throw AIAssistantError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.aiAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        var apiMessages: [[String: String]] = [
            ["role": "system", "content": makeSystemPrompt(terminalContext: systemContext)]
        ]
        for message in messages {
            apiMessages.append(["role": message.role.rawValue, "content": message.content])
        }

        let body: [String: Any] = [
            "model": settings.aiModel,
            "messages": apiMessages,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let data = try await bytes.reduce(into: Data()) { $0.append($1) }
            let text = String(data: data, encoding: .utf8) ?? L("未知错误")
            throw AIAssistantError.httpError(statusCode: httpResponse.statusCode, message: text)
        }

        let thinkingFilter = AIThinkingFilter()
        var displayContent = ""

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]" else { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }

            // 只处理正式 content，忽略 reasoning/thinking 字段以及 <think> 标签块。
            if let content = delta["content"] as? String {
                let visible = thinkingFilter.append(content)
                displayContent += visible
                onUpdate(displayContent)
            }
        }

        return displayContent
    }

    /// 构造 AI 的 system prompt（与 Mac 版 makeSystemPrompt 一致）。
    ///
    /// 终端上下文快照（OS 身份 / xtop 资源快照 / Git / 工具 / 环境变量）
    /// 作为参考信息嵌入，并附带使用规则：
    /// - OS family 行是权威的：macOS 终端必须按 macOS 语义回答命令问题
    ///   （用户实测问题：问命令参数时 AI 按 Linux 标准回答，mac 环境下错误）
    /// - 资源数字是时刻快照，仅作参考
    /// - 优先推荐上下文中已安装的工具
    static func makeSystemPrompt(terminalContext: String) -> String {
        """
        You are a helpful terminal assistant integrated into ExGhostty.
        The user is currently working in a terminal. Use the following terminal context to provide relevant help:

        \(terminalContext)

        Rules for using the terminal context:
        - It is a snapshot collected at request time on the machine the user is working on (the remote server the terminal is connected to over SSH).
        - The "OS family" line is authoritative. If it says macOS, answer all command/parameter/behavior questions with macOS semantics (zsh, BSD awk/sed/grep, sysctl, launchctl, Homebrew, no /proc); if it says Linux, use the Linux defaults. Never mix the two.
        - When explaining a command's parameters or behavior, describe how that command behaves on the OS stated in the context; only mention differences on other OSes briefly.
        - Resource numbers (CPU / memory / disk / GPU / network / processes, e.g. from the xtop JSON snapshot) are a point-in-time sample; treat them as reference values, not live measurements.
        - When suggesting commands, prefer tools the context says are installed.

        When answering, prefer concise, actionable responses, and answer in the same language the user uses.
        If your answer includes a command that the user can run in the terminal, put it inside a fenced code block with the language tag `command`, like this:
        ```command
        ls -la
        ```
        Do not include explanations inside the code blocks; keep only the executable command. One code block per command or tightly related command group.
        """
    }
}

/// 流式过滤掉 <think>...</think> 包裹的 thinking 内容。
private final class AIThinkingFilter {
    private var buffer: String = ""
    private var inThinkBlock: Bool = false

    /// 追加新的文本片段，返回过滤掉 thinking 后可显示的部分。
    func append(_ chunk: String) -> String {
        buffer += chunk
        var result = ""

        while !buffer.isEmpty {
            if inThinkBlock {
                guard let endRange = buffer.range(of: "</think>") else {
                    buffer = ""
                    return result
                }
                buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
                inThinkBlock = false
            } else {
                guard let startRange = buffer.range(of: "<think>") else {
                    // 保留末尾可能未完整的 <think> 起始片段，避免把 partial tag 显示出来。
                    if let ltIndex = buffer.lastIndex(of: "<") {
                        let suffix = String(buffer[ltIndex...])
                        let thinkPrefix = "<think>"
                        if thinkPrefix.hasPrefix(suffix) {
                            result += String(buffer[..<ltIndex])
                            buffer = String(buffer[ltIndex...])
                            return result
                        }
                    }
                    result += buffer
                    buffer = ""
                    return result
                }
                result += String(buffer[..<startRange.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<startRange.upperBound)
                inThinkBlock = true
            }
        }

        return result
    }
}
