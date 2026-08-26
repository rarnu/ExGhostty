import Foundation
import AppKit
import Combine

/// AI 服务配置。
struct AIConfiguration {
    var endpoint: String
    var apiKey: String
    var model: String

    /// API Key 可为空：部分服务（本地模型、免密钥网关等）不需要鉴权。
    var isValid: Bool {
        !endpoint.isEmpty && !model.isEmpty
    }
}

/// 用于与兼容 OpenAI 的 AI 接口通信并流式接收应答。
@MainActor
final class AIAssistantService: ObservableObject {
    static let shared = AIAssistantService()

    @Published var configuration: AIConfiguration = AIConfiguration(endpoint: "", apiKey: "", model: "")

    private var configObserver: NSObjectProtocol?

    private init() {
        loadConfiguration()

        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadConfiguration()
            }
        }
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 从配置文件或 UserDefaults 加载 AI 配置。
    private func loadConfiguration() {
        var endpoint: String?
        var apiKey: String?
        var model: String?

        if let url = (NSApp.delegate as? AppDelegate)?.ghostty.configFileURL {
            let writer = ConfigFileWriter(url: url)
            endpoint = writer.firstValue(for: "ai-endpoint")
            apiKey = writer.firstValue(for: "ai-apikey")
            model = writer.firstValue(for: "ai-model")
        }

        let ud = UserDefaults.ghostty
        endpoint = endpoint ?? ud.string(forKey: "ai-endpoint")
        apiKey = apiKey ?? ud.string(forKey: "ai-apikey")
        model = model ?? ud.string(forKey: "ai-model")

        configuration = AIConfiguration(
            endpoint: endpoint ?? "",
            apiKey: apiKey ?? "",
            model: model ?? ""
        )
    }

    /// 构造 AI 的 system prompt。
    ///
    /// 终端上下文快照（OS 身份 / xtop 资源快照 / Git / 工具 / 环境变量）
    /// 作为参考信息嵌入，并附带使用规则：
    /// - OS family 行是权威的：macOS 终端必须按 macOS 语义回答命令问题
    ///   （用户实测问题：问命令参数时 AI 按 Linux 标准回答，mac 环境下错误）
    /// - 资源数字是时刻快照，仅作参考
    /// - 优先推荐上下文中已安装的工具
    ///
    /// 抽成独立方法便于单元测试。
    internal static func makeSystemPrompt(terminalContext: String) -> String {
        """
        You are a helpful terminal assistant integrated into ExGhostty.
        The user is currently working in a terminal. Use the following terminal context to provide relevant help:

        \(terminalContext)

        Rules for using the terminal context:
        - It is a snapshot collected at request time on the machine the user is working on (the local host, or the remote server when the terminal is an SSH session).
        - The "OS family" line is authoritative. If it says macOS, answer all command/parameter/behavior questions with macOS semantics (zsh, BSD awk/sed/grep, sysctl, launchctl, Homebrew, no /proc); if it says Linux, use the Linux defaults. Never mix the two.
        - When explaining a command's parameters or behavior, describe how that command behaves on the OS stated in the context; only mention differences on other OSes briefly.
        - Resource numbers (CPU / memory / disk / GPU / network / processes, e.g. from the xtop JSON snapshot) are a point-in-time sample; treat them as reference values, not live measurements.
        - When suggesting commands, prefer tools the context says are installed.

        When answering, prefer concise, actionable responses.
        If your answer includes a command that the user can run in the terminal, put it inside a fenced code block with the language tag `command`, like this:
        ```command
        ls -la
        ```
        If your answer includes a simple Python script that the user can run, put it inside a fenced code block with the language tag `python`, like this:
        ```python
        print("hello")
        ```
        Do not include explanations inside the code blocks; keep only the executable command or script.
        """
    }

    /// 发送消息并流式返回 AI 应答。
    /// - Parameters:
    ///   - messages: 已发送/接收的消息列表，会一并作为上下文。
    ///   - terminalContext: 当前终端信息，作为 system prompt 的一部分。
    ///   - onUpdate: 每收到一段流式内容即回调一次。
    /// - Returns: 完整的 AI 应答文本。
    func sendMessage(
        messages: [AIMessage],
        terminalContext: String,
        onUpdate: @escaping (String) -> Void
    ) async throws -> String {
        guard configuration.isValid else {
            throw AIAssistantError.configurationMissing
        }

        guard let url = URL(string: configuration.endpoint)?.appendingPathComponent("chat/completions") else {
            throw AIAssistantError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        var apiMessages: [[String: String]] = []
        apiMessages.append(["role": "system", "content": Self.makeSystemPrompt(terminalContext: terminalContext)])

        for message in messages {
            apiMessages.append(["role": message.role.rawValue, "content": message.content])
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "messages": apiMessages,
            "stream": true,
            "stream_options": ["include_usage": false]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 将完整请求 body 保存到日志文件
        if let jsonData = request.httpBody,
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let logPath = NSHomeDirectory() + "/exghostty_ai_request.log"
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "=== \(timestamp) ===\n\(jsonString)\n\n"
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(entry.data(using: .utf8) ?? Data())
                fh.closeFile()
            } else {
                try? entry.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
            }
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIAssistantError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let data = try await bytes.reduce(into: Data()) { $0.append($1) }
            let text = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIAssistantError.httpError(statusCode: httpResponse.statusCode, message: text)
        }

        let thinkingFilter = AIThinkingFilter()
        var displayContent = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
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

enum AIAssistantError: LocalizedError {
    case configurationMissing
    case invalidEndpoint
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "AI configuration is missing. Please set ai-endpoint and ai-model in settings.".localized
        case .invalidEndpoint:
            return "Invalid AI endpoint URL.".localized
        case .invalidResponse:
            return "Invalid response from AI service.".localized
        case .httpError(let statusCode, let message):
            return String(format: "AI request failed (%d): %@".localized, statusCode, message)
        }
    }
}
