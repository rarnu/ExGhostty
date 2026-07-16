import AppKit
import SwiftUI
import Combine

/// 远端/本机操作系统类型，用于按平台拼接 tmux/zellij 命令。
enum HostOS: String, CaseIterable, Identifiable {
    case linux
    case macOS

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        }
    }
}

/// 会话类型，用于区分 tmux / zellij 的通用操作。
enum SessionType: String, CaseIterable, Identifiable {
    case tmux
    case zellij

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tmux: return "tmux"
        case .zellij: return "zellij"
        }
    }
}

/// 删除会话确认数据。
struct DeleteConfirmation: Identifiable {
    let id = UUID()
    let type: SessionType
    let name: String
}

/// 会话复用面板视图模型。
final class SessionReusePanelViewModel: ObservableObject {
    weak var terminalController: TerminalController?
    let connection: SSHConnection?

    @Published var hostOS: HostOS?
    @Published var tmuxInstalled: Bool = false
    @Published var zellijInstalled: Bool = false
    @Published var tmuxSessions: [String] = []
    @Published var zellijSessions: [String] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - 模态/确认状态

    @Published var deleteConfirmation: DeleteConfirmation?

    private var refreshTimer: Timer?

    init(terminalController: TerminalController?) {
        self.terminalController = terminalController
        self.connection = terminalController?.sshConnection
        detectHostOS()
        Task { @MainActor in
            self.refresh()
        }
        startRefreshTimer()
    }

    deinit {
        stopRefreshTimer()
    }

    // MARK: - 刷新

    @MainActor
    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        Task {
            async let tmuxInstalledTask = checkInstalled(command: "tmux")
            async let zellijInstalledTask = checkInstalled(command: "zellij")

            let tmuxInstalled = await tmuxInstalledTask
            let zellijInstalled = await zellijInstalledTask

            async let tmuxSessionsTask = tmuxInstalled ? listTmuxSessions() : []
            async let zellijSessionsTask = zellijInstalled ? listZellijSessions() : []

            self.tmuxInstalled = tmuxInstalled
            self.zellijInstalled = zellijInstalled
            self.tmuxSessions = await tmuxSessionsTask
            self.zellijSessions = await zellijSessionsTask
            self.isLoading = false
        }
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - 主机系统检测

    private func detectHostOS() {
        Task {
            do {
                let output: String
                if let connection = connection {
                    output = try await SSHCommandExecutor.shared.execute(
                        remoteCommand: "uname -s",
                        connection: connection
                    )
                } else {
                    output = try await ProcessRunner.run(shellCommand: "uname -s")
                }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let detected: HostOS? = switch trimmed {
                case "Darwin": .macOS
                case "Linux": .linux
                default: nil
                }
                await MainActor.run {
                    self.hostOS = detected
                }
            } catch {
                await MainActor.run {
                    self.hostOS = nil
                }
            }
        }
    }

    private func currentOS() -> HostOS {
        hostOS ?? .linux
    }

    // MARK: - 工具安装检测

    private func checkInstalled(command: String) async -> Bool {
        if let connection = connection {
            if await remoteExecutablePath(for: command, connection: connection) != nil {
                return true
            }
            let fallback = """
            if [ -n "$SHELL" ]; then "$SHELL" -l -c "command -v \(command)"; else command -v \(command); fi
            """
            do {
                _ = try await SSHCommandExecutor.shared.execute(
                    remoteCommand: fallback,
                    connection: connection
                )
                return true
            } catch {
                return false
            }
        } else {
            if localExecutablePath(for: command) != nil {
                return true
            }
            do {
                _ = try await ProcessRunner.run(shellCommand: "which \(command)")
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - 会话列表

    private func listTmuxSessions() async -> [String] {
        do {
            let executable: String
            let output: String
            if let connection = connection {
                executable = await remoteExecutablePath(for: "tmux", connection: connection) ?? "tmux"
                output = try await SSHCommandExecutor.shared.execute(
                    remoteCommand: "\(executable.singleQuotedShellArgument()) list-sessions -F '#S'",
                    connection: connection
                )
            } else {
                executable = localExecutablePath(for: "tmux") ?? "command tmux"
                output = try await ProcessRunner.run(shellCommand: "\(executable) list-sessions -F '#S'")
            }
            return output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        } catch {
            // 远端 tmux 服务器未运行时返回错误，按无会话处理。
            return []
        }
    }

    private func listZellijSessions() async -> [String] {
        do {
            let executable: String
            let output: String
            if let connection = connection {
                executable = await remoteExecutablePath(for: "zellij", connection: connection) ?? "zellij"
                output = try await SSHCommandExecutor.shared.execute(
                    remoteCommand: "\(executable.singleQuotedShellArgument()) list-sessions",
                    connection: connection
                )
            } else {
                executable = localExecutablePath(for: "zellij") ?? "zellij"
                output = try await ProcessRunner.run(shellCommand: "\(executable) list-sessions")
            }
            return output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    let cleaned = String(line).strippingANSISequences()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return nil }
                    let first = cleaned.split(separator: " ", omittingEmptySubsequences: true).first
                    return first.map(String.init)
                }
        } catch {
            return []
        }
    }

    // MARK: - 可执行文件定位

    /// macOS 上常见安装路径（Homebrew Apple/Intel、MacPorts、cargo）。
    private func candidatePaths(for command: String) -> [String] {
        [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/opt/local/bin/\(command)",
            "~/.cargo/bin/\(command)",
        ]
    }

    private func localExecutablePath(for command: String) -> String? {
        for path in candidatePaths(for: command) {
            let expanded = path.replacingOccurrences(of: "~", with: NSHomeDirectory())
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return nil
    }

    private func remoteExecutablePath(for command: String, connection: SSHConnection) async -> String? {
        let tests = candidatePaths(for: command)
            .map { "test -x \($0) && echo \($0)" }
            .joined(separator: " || ")
        do {
            let output = try await SSHCommandExecutor.shared.execute(
                remoteCommand: tests,
                connection: connection
            )
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    // MARK: - 发送到终端

    @MainActor
    private func sendToTerminal(_ command: String) {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else { return }
        // 先发命令文本，再模拟按一下回车键。直接用 \r/\n 文本在某些 PTY 输入模式下不会被识别为提交，
        // 而发送真正的 Return 键事件可以复用 Ghostty 的键盘编码路径，和手动按回车一致。
        surface.sendText(command)
        surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press, text: "\r"))
    }

    /// 依次发送一组按键事件，按键之间留一个小间隔，避免 multiplexer 把组合键当成同时按下。
    @MainActor
    private func sendKeyEvents(_ events: [Ghostty.Input.KeyEvent], delayNanoseconds: UInt64 = 80_000_000) {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else { return }
        Task { @MainActor in
            for (index, event) in events.enumerated() {
                if index > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                surface.sendKeyEvent(event)
            }
        }
    }

    // MARK: - 命令拼接

    private func tmuxNewSessionCommand(name: String) -> String {
        let escaped = name.singleQuotedShellArgument()
        return "tmux new -s \(escaped)"
    }

    private func tmuxAttachCommand(session: String) -> String {
        let escaped = session.singleQuotedShellArgument()
        return "if [ -n \"$TMUX\" ]; then tmux switch-client -t \(escaped); else tmux attach-session -t \(escaped); fi"
    }

    private func tmuxKillSessionCommand(session: String) -> String {
        let escaped = session.singleQuotedShellArgument()
        return "tmux kill-session -t \(escaped)"
    }

    private func zellijNewSessionCommand(name: String) -> String {
        let escaped = name.singleQuotedShellArgument()
        return "zellij attach --create \(escaped)"
    }

    private func zellijAttachCommand(session: String) -> String {
        let escaped = session.singleQuotedShellArgument()
        return "zellij attach \(escaped)"
    }

    private func zellijKillSessionCommand(session: String) -> String {
        let escaped = session.singleQuotedShellArgument()
        return "zellij kill-session \(escaped)"
    }

    // MARK: - 操作入口

    @MainActor
    func promptNewSession(type: SessionType) {
        guard let tc = terminalController, let window = tc.window else { return }
        let controller = GroupNameWindowController(
            title: "新建\(type.displayName)会话",
            message: "输入\(type.displayName)会话名称",
            placeholder: "会话名称",
            confirmTitle: "确认",
            cancelTitle: "取消",
            filter: { text in
                // tmux/zellij 会话名仅允许英文和数字。
                text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            },
            config: tc.ghostty.config,
            parentWindow: window,
            completion: { [weak self] name in
                guard let self = self, let name = name else { return }
                self.confirmNewSession(type: type, name: name)
            }
        )
        controller.showModal()
    }

    @MainActor
    private func confirmNewSession(type: SessionType, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch type {
        case .tmux:
            sendToTerminal(tmuxNewSessionCommand(name: trimmed))
        case .zellij:
            sendToTerminal(zellijNewSessionCommand(name: trimmed))
        }
    }

    @MainActor
    func detachTmux() {
        // sendText 会把控制字符当成粘贴显示成 ^B，所以这里必须用键盘事件。
        // macOS 用 nil text 时 tmux 能正确识别前缀；Linux 需要显式带上控制字符 text。
        switch currentOS() {
        case .macOS:
            sendKeyEvents([
                Ghostty.Input.KeyEvent(key: .b, action: .press, mods: .ctrl),
                Ghostty.Input.KeyEvent(key: .d, action: .press, text: "d"),
            ])
        case .linux:
            sendKeyEvents([
                Ghostty.Input.KeyEvent(key: .b, action: .press, text: "\u{0002}", mods: .ctrl),
                Ghostty.Input.KeyEvent(key: .d, action: .press, text: "d"),
            ])
        }
    }

    @MainActor
    func attachTmux(session: String) {
        sendToTerminal(tmuxAttachCommand(session: session))
    }

    @MainActor
    func killTmux(session: String) {
        sendToTerminal(tmuxKillSessionCommand(session: session))
    }

    @MainActor
    func detachZellij() {
        // zellij 的 prefix 是 Ctrl+o（ASCII 0x0F），必须同时发送控制字符文本，
        // 否则在 macOS 上只会把后面的 d 当普通字符输出。
        sendKeyEvents([
            Ghostty.Input.KeyEvent(key: .o, action: .press, text: "\u{000F}", mods: .ctrl),
            Ghostty.Input.KeyEvent(key: .d, action: .press, text: "d"),
        ])
    }

    @MainActor
    func attachZellij(session: String) {
        sendToTerminal(zellijAttachCommand(session: session))
    }

    @MainActor
    func killZellij(session: String) {
        sendToTerminal(zellijKillSessionCommand(session: session))
    }
}

// MARK: - 视图

/// 会话复用功能面板。
struct SessionReusePanelView: View {
    @StateObject private var viewModel: SessionReusePanelViewModel

    init(terminalController: TerminalController?) {
        _viewModel = StateObject(wrappedValue: SessionReusePanelViewModel(terminalController: terminalController))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(item: $viewModel.deleteConfirmation) { item in
            deleteAlert(item: item)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.tmuxInstalled && !viewModel.zellijInstalled {
            Spacer()
            ProgressView()
            Spacer()
        } else if !viewModel.tmuxInstalled && !viewModel.zellijInstalled {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("请安装 tmux 或 zellij")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.tmuxInstalled {
                        sessionSection(
                            type: .tmux,
                            title: "tmux",
                            icon: "terminal",
                            newLabel: "新建tmux会话",
                            newAction: { viewModel.promptNewSession(type: .tmux) },
                            detachLabel: "从当前会话分离",
                            detachAction: { viewModel.detachTmux() },
                            sessions: viewModel.tmuxSessions,
                            attachAction: { viewModel.attachTmux(session: $0) }
                        )

                        if viewModel.zellijInstalled {
                            Divider()
                                .padding(.horizontal, 8)
                        }
                    }

                    if viewModel.zellijInstalled {
                        sessionSection(
                            type: .zellij,
                            title: "zellij",
                            icon: "square.grid.2x2",
                            newLabel: "新建zellij会话",
                            newAction: { viewModel.promptNewSession(type: .zellij) },
                            detachLabel: "从当前会话分离",
                            detachAction: { viewModel.detachZellij() },
                            sessions: viewModel.zellijSessions,
                            attachAction: { viewModel.attachZellij(session: $0) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func deleteAlert(item: DeleteConfirmation) -> Alert {
        Alert(
            title: Text("删除\(item.type.displayName)会话"),
            message: Text("确定要删除会话 \"\(item.name)\" 吗？此操作不可撤销。"),
            primaryButton: .destructive(Text("删除")) {
                switch item.type {
                case .tmux: viewModel.killTmux(session: item.name)
                case .zellij: viewModel.killZellij(session: item.name)
                }
            },
            secondaryButton: .cancel(Text("取消"))
        )
    }

    private func sessionSection(
        type: SessionType,
        title: String,
        icon: String,
        newLabel: String,
        newAction: @escaping () -> Void,
        detachLabel: String,
        detachAction: @escaping () -> Void,
        sessions: [String],
        attachAction: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 分类标题：更醒目的头部
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button(action: newAction) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(newLabel)

                Button(action: detachAction) {
                    Image(systemName: "escape")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(detachLabel)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.top, 6)

            if sessions.isEmpty {
                HStack {
                    Text("暂无会话")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                ForEach(sessions, id: \.self) { session in
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 16)

                        Text(session)
                            .font(.system(size: 12))
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("连接") {
                            attachAction(session)
                        }
                        Divider()
                        Button(role: .destructive) {
                            viewModel.deleteConfirmation = DeleteConfirmation(type: type, name: session)
                        } label: {
                            Text("删除")
                                .foregroundColor(.red)
                        }
                    }
                    .onTapGesture(count: 2) {
                        attachAction(session)
                    }
                }
            }
        }
    }
}
