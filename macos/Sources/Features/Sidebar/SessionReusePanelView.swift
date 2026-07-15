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
                    output = try await SFTPService.shared.executeCommand(
                        connection: connection,
                        remoteCommand: "uname -s"
                    )
                } else {
                    output = try await runLocalCommand(["/usr/bin/uname", "-s"])
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
        do {
            if let connection = connection {
                _ = try await SFTPService.shared.executeCommand(
                    connection: connection,
                    remoteCommand: "command -v \(command)"
                )
            } else {
                _ = try await runLocalCommand(["/usr/bin/env", "which", command])
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - 会话列表

    private func listTmuxSessions() async -> [String] {
        do {
            let output: String
            if let connection = connection {
                output = try await SFTPService.shared.executeCommand(
                    connection: connection,
                    remoteCommand: "tmux list-sessions -F '#S'"
                )
            } else {
                output = try await runLocalCommand(["/usr/bin/env", "tmux", "list-sessions", "-F", "#S"])
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
            let output: String
            if let connection = connection {
                output = try await SFTPService.shared.executeCommand(
                    connection: connection,
                    remoteCommand: "zellij list-sessions"
                )
            } else {
                output = try await runLocalCommand(["/usr/bin/env", "zellij", "list-sessions"])
            }
            return output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return nil }
                    let first = trimmed.split(separator: " ", omittingEmptySubsequences: true).first
                    return first.map(String.init)
                }
        } catch {
            return []
        }
    }

    // MARK: - 本地命令执行

    private func runLocalCommand(_ args: [String]) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = Array(args.dropFirst())

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { _ in
                let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SessionReuse",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderr]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - 发送到终端

    @MainActor
    private func sendToTerminal(_ command: String) {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else { return }
        surface.sendText(command + "\r")
    }

    // MARK: - 命令拼接

    private func tmuxNewSessionCommand(os: HostOS) -> String {
        switch os {
        case .linux, .macOS:
            return "tmux new-session"
        }
    }

    private func tmuxDetachCommand(os: HostOS) -> String {
        switch os {
        case .linux, .macOS:
            return "tmux detach"
        }
    }

    private func tmuxAttachCommand(os: HostOS, session: String) -> String {
        let escaped = session.replacingOccurrences(of: "\"", with: "\\\"")
        switch os {
        case .linux, .macOS:
            return "tmux attach -t \"\(escaped)\""
        }
    }

    private func zellijNewSessionCommand(os: HostOS) -> String {
        switch os {
        case .linux, .macOS:
            return "zellij"
        }
    }

    private func zellijDetachCommand(os: HostOS) -> String {
        switch os {
        case .linux, .macOS:
            return "zellij action detach"
        }
    }

    private func zellijAttachCommand(os: HostOS, session: String) -> String {
        let escaped = session.replacingOccurrences(of: "\"", with: "\\\"")
        switch os {
        case .linux, .macOS:
            return "zellij attach \"\(escaped)\""
        }
    }

    // MARK: - 操作入口

    @MainActor
    func newTmuxSession() {
        sendToTerminal(tmuxNewSessionCommand(os: currentOS()))
    }

    @MainActor
    func detachTmux() {
        sendToTerminal(tmuxDetachCommand(os: currentOS()))
    }

    @MainActor
    func attachTmux(session: String) {
        sendToTerminal(tmuxAttachCommand(os: currentOS(), session: session))
    }

    @MainActor
    func newZellijSession() {
        sendToTerminal(zellijNewSessionCommand(os: currentOS()))
    }

    @MainActor
    func detachZellij() {
        sendToTerminal(zellijDetachCommand(os: currentOS()))
    }

    @MainActor
    func attachZellij(session: String) {
        sendToTerminal(zellijAttachCommand(os: currentOS(), session: session))
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
                            title: "tmux",
                            icon: "terminal",
                            newLabel: "新建tmux会话",
                            newAction: { viewModel.newTmuxSession() },
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
                            title: "zellij",
                            icon: "square.grid.2x2",
                            newLabel: "新建zellij会话",
                            newAction: { viewModel.newZellijSession() },
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

    private func sessionSection(
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
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                Text(title)
                    .font(.system(size: 13, weight: .medium))

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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

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
                    .onTapGesture(count: 2) {
                        attachAction(session)
                    }
                }
            }
        }
    }
}
