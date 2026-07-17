import SwiftUI
import AppKit
import Combine
import GhosttyKit

/// AI 助手面板视图模型。
@MainActor
final class AIAssistantPanelViewModel: ObservableObject {
    weak var terminalController: TerminalController?

    @Published var conversation: AIConversation
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var inputHeight: CGFloat = 100
    @Published var showHistory: Bool = false

    private var currentTask: Task<Void, Never>?

    init(terminalController: TerminalController?) {
        self.terminalController = terminalController
        self.conversation = AIConversation(title: "New Conversation".localized)
    }

    /// 收集当前终端上下文，作为 system prompt。
    func terminalContextString() -> String {
        var parts: [String] = []

        if let url = terminalController?.currentDirectoryURL {
            parts.append("Current directory: \(url.path)")
        } else {
            parts.append("Current directory: unknown")
        }

        if let ssh = terminalController?.sshConnection {
            parts.append("SSH connection: \(ssh.name) (\(ssh.username)@\(ssh.host):\(ssh.port))")
        } else {
            parts.append("Connection: local terminal")
        }

        if let title = terminalController?.focusedSurfaceRawTitle, !title.isEmpty {
            parts.append("Terminal title: \(title)")
        }

        return parts.joined(separator: "\n")
    }

    /// 发送用户输入的消息。
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        inputText = ""
        errorMessage = nil

        let userMessage = AIMessage(role: .user, content: text)
        conversation.messages.append(userMessage)
        saveConversation()

        isLoading = true

        let assistantMessage = AIMessage(role: .assistant, content: "")
        conversation.messages.append(assistantMessage)
        let assistantIndex = conversation.messages.count - 1

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            let context = self.terminalContextString()
            let messages = self.conversation.messages

            do {
                let result = try await AIAssistantService.shared.sendMessage(
                    messages: messages,
                    terminalContext: context
                ) { [weak self] partial in
                    guard let self else { return }
                    self.conversation.messages[assistantIndex].content = partial
                    self.objectWillChange.send()
                }

                self.conversation.messages[assistantIndex].content = result
                self.conversation.updatedAt = Date()
                self.saveConversation()
            } catch is CancellationError {
                // 用户取消，不报错
            } catch {
                self.errorMessage = error.localizedDescription
                // 移除未完成的助手消息
                if self.conversation.messages.count > assistantIndex {
                    self.conversation.messages.remove(at: assistantIndex)
                    self.saveConversation()
                }
            }

            self.isLoading = false
        }
    }

    /// 取消当前正在接收的 AI 响应。
    func cancel() {
        currentTask?.cancel()
    }

    /// 将 AI 生成的命令或脚本按语言类型包装后，复制到当前聚焦的终端，但不自动执行。
    func runCode(language: String, code: String) {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else { return }

        let textToSend: String
        switch language.lowercased() {
        case "python":
            let delimiter = "GHOSTTY_PY_EOF_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            textToSend = "python3 << '\(delimiter)'\n\(code)\n\(delimiter)"
        case "command", "shell", "bash", "zsh":
            textToSend = code
        default:
            textToSend = code
        }

        surface.sendText(textToSend)
    }

    /// 将 AI 生成的代码复制到剪贴板。
    func copyCode(code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }

    /// 新建对话。如果当前对话已有消息，则先保存到历史。
    func newConversation() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
        errorMessage = nil
        showHistory = false

        if !conversation.messages.isEmpty {
            AIAssistantHistoryStore.shared.save(conversation)
        }

        conversation = AIConversation(title: "New Conversation".localized)
    }

    /// 从历史中加载一条对话。当前对话会先保存。
    func loadConversation(_ target: AIConversation) {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
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

    /// 删除当前对话并新建。
    func deleteCurrentConversation() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
        errorMessage = nil

        AIAssistantHistoryStore.shared.delete(id: conversation.id)
        conversation = AIAssistantHistoryStore.shared.createConversation()
    }

    private func saveConversation() {
        AIAssistantHistoryStore.shared.save(conversation)
    }
}

// MARK: - Panel View

struct AIAssistantPanelView: View {
    @StateObject private var viewModel: AIAssistantPanelViewModel
    @State private var dragStartHeight: CGFloat?

    init(terminalController: TerminalController?) {
        _viewModel = StateObject(wrappedValue: AIAssistantPanelViewModel(terminalController: terminalController))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if viewModel.showHistory {
                AIHistoryListView(
                    onSelect: { conversation in
                        viewModel.loadConversation(conversation)
                    },
                    onDismiss: {
                        viewModel.showHistory = false
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chatContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                dragHandle

                inputArea
                    .frame(height: viewModel.inputHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.newConversation()
            } label: {
                Label("New Chat".localized, systemImage: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)

            Button {
                viewModel.showHistory = true
            } label: {
                Label("History".localized, systemImage: "clock")
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)

            Spacer()

            if AIAssistantService.shared.configuration.isValid {
                Text(AIAssistantService.shared.configuration.model)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text("AI not configured".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var chatContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.conversation.messages) { message in
                        AIAssistantMessageView(
                            message: message,
                            onRunCode: { language, code in
                                viewModel.runCode(language: language, code: code)
                            },
                            onCopyCode: { code in
                                viewModel.copyCode(code: code)
                            }
                        )
                            .id(message.id)
                    }

                    if viewModel.isLoading &&
                        viewModel.conversation.messages.last?.role != .assistant {
                        AIAssistantTypingIndicator()
                    }

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.conversation.messages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.conversation.messages.last?.content) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var dragHandle: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 12)
                    .contentShape(Rectangle())
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = viewModel.inputHeight
                        }
                        let delta = -value.translation.height
                        let newHeight = max(100, min(500, (dragStartHeight ?? viewModel.inputHeight) + delta))
                        viewModel.inputHeight = newHeight
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
            .cursor(.resizeUpDown)
    }

    private var inputArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AIInputTextView(
                    text: $viewModel.inputText,
                    onSubmit: { viewModel.sendMessage() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if viewModel.inputText.isEmpty {
                        Text("Type your questions.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.leading, 5)
                            .padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                }

                if viewModel.isLoading {
                    Button {
                        viewModel.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .help("Cancel".localized)
                    .frame(width: 32, height: 32)
                } else {
                    Button {
                        viewModel.sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send".localized)
                    .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.clear)
    }
}

// MARK: - Input Text View

private struct AIInputTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        let textView = AIInputSubmitTextView()
        let coordinator = context.coordinator
        textView.onSubmit = { [weak coordinator] in
            coordinator?.submit()
        }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? AIInputSubmitTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIInputTextView

        init(_ parent: AIInputTextView) {
            self.parent = parent
        }

        func submit() {
            parent.onSubmit()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// 支持 Ctrl+Enter / Shift+Enter 提交的自定义 NSTextView。
private final class AIInputSubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 &&
            (event.modifierFlags.contains(.control) || event.modifierFlags.contains(.shift)) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Message View

private struct AIAssistantMessageView: View {
    let message: AIMessage
    var onRunCode: ((String, String) -> Void)?
    var onCopyCode: ((String) -> Void)?

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    Text("AI".localized)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }

                messageContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15))
                    .foregroundColor(message.role == .user ? .white : .primary)
                    .cornerRadius(12)
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.role == .assistant {
            let segments = parseMessageContent(message.content)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        formattedText(text)
                    case .code(let language, let code):
                        AICodeBlockView(language: language, code: code, onRun: onRunCode, onCopy: onCopyCode)
                    }
                }
            }
        } else {
            Text(message.content)
                .textSelection(.enabled)
        }
    }

    private func formattedText(_ text: String) -> some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                Text(attributed)
                    .textSelection(.enabled)
            } else {
                Text(text)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Content Parser

private enum AIMessageSegment {
    case text(String)
    case code(language: String, content: String)
}

private func parseMessageContent(_ content: String) -> [AIMessageSegment] {
    var segments: [AIMessageSegment] = []
    var plainTextLines: [String] = []
    var inCodeBlock = false
    var codeLanguage = ""
    var codeLines: [String] = []

    func flushText() {
        if !plainTextLines.isEmpty {
            segments.append(.text(plainTextLines.joined(separator: "\n")))
            plainTextLines.removeAll()
        }
    }

    for line in content.components(separatedBy: .newlines) {
        if inCodeBlock {
            if line.hasPrefix("```") {
                flushText()
                segments.append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                codeLanguage = ""
                inCodeBlock = false
            } else {
                codeLines.append(line)
            }
        } else {
            if line.hasPrefix("```") {
                flushText()
                codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inCodeBlock = true
            } else {
                plainTextLines.append(line)
            }
        }
    }

    if inCodeBlock {
        // 未闭合的代码块，作为普通文本拼回
        plainTextLines.append("```" + codeLanguage + (codeLines.isEmpty ? "" : "\n" + codeLines.joined(separator: "\n")))
    }
    flushText()

    return segments
}

// MARK: - Code Block View

private struct AICodeBlockView: View {
    let language: String
    let code: String
    var onRun: ((String, String) -> Void)?
    var onCopy: ((String) -> Void)?

    private var isRunnable: Bool {
        ["command", "python"].contains(language.lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(languageLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        onCopy?(code)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Copy".localized)

                    if isRunnable {
                        Button {
                            onRun?(language, code)
                        } label: {
                            Image(systemName: "play")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to Terminal".localized)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background(Color.black.opacity(0.45))
        .cornerRadius(8)
    }

    private var languageLabel: String {
        switch language.lowercased() {
        case "command": return "Command".localized
        case "python": return "Python".localized
        case "": return "Code".localized
        default: return language.capitalized
        }
    }
}

// MARK: - Typing Indicator

private struct AIAssistantTypingIndicator: View {
    @State private var phase = 0
    @State private var timer: Timer?

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .foregroundColor(.secondary)
                        .opacity(phase == index ? 1.0 : 0.4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(12)

            Spacer(minLength: 40)
        }
        .onAppear {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Cursor Extension

private extension View {
    func cursor(_ type: NSCursor) -> some View {
        self.onHover { isHovering in
            if isHovering {
                type.push()
            } else {
                type.pop()
            }
        }
    }
}
