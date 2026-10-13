import AppKit
import SwiftUI
import Combine

/// 远端/本机操作系统类型，用于按平台拼接 tmux/rmux/zellij 命令。
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

/// 会话类型，用于区分 tmux / rmux / zellij 的通用操作。
enum SessionType: String, CaseIterable, Identifiable {
    case tmux
    case rmux
    case zellij

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tmux: return "tmux"
        case .rmux: return "rmux"
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
    @Published var rmuxInstalled: Bool = false
    @Published var zellijInstalled: Bool = false
    @Published var tmuxSessions: [String] = []
    @Published var rmuxSessions: [String] = []
    @Published var zellijSessions: [String] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - 模态/确认状态

    @Published var deleteConfirmation: DeleteConfirmation?

    private var refreshTimer: Timer?

    init(terminalController: TerminalController?) {
        self.terminalController = terminalController
        self.connection = terminalController?.sshConnection
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
            let snapshot = await fetchSnapshot()
            // 仅成功时覆盖状态；失败（断网/合盖唤醒瞬间）保留旧数据，避免面板闪空。
            if let snapshot {
                if let os = snapshot.hostOS { self.hostOS = os }
                self.tmuxInstalled = snapshot.tmuxInstalled
                self.rmuxInstalled = snapshot.rmuxInstalled
                self.zellijInstalled = snapshot.zellijInstalled
                self.tmuxSessions = snapshot.tmuxSessions
                self.rmuxSessions = snapshot.rmuxSessions
                self.zellijSessions = snapshot.zellijSessions
            } else {
                self.errorMessage = "Failed to refresh session list".localized
            }
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

    // MARK: - 单次远程探测

    /// 一次刷新所需的全部信息快照。
    private struct Snapshot {
        var hostOS: HostOS?
        var tmuxPath = ""
        var rmuxPath = ""
        var zellijPath = ""
        var tmuxSessions: [String] = []
        var rmuxSessions: [String] = []
        var zellijSessions: [String] = []

        var tmuxInstalled: Bool { !tmuxPath.isEmpty }
        var rmuxInstalled: Bool { !rmuxPath.isEmpty }
        var zellijInstalled: Bool { !zellijPath.isEmpty }
    }

    /// 单条命令完成 OS 探测、tmux/rmux/zellij 安装探测（含可执行文件路径）与会话列举。
    ///
    /// 此前每次刷新要执行约 10 条命令（每个工具探测路径、登录 shell 回退、列表各一次），
    /// 而 SSHCommandExecutor 是 actor，所有命令串行排队；控制通道失效时每条命令还要各做
    /// 一次完整 SSH 握手，断网/合盖唤醒后一次刷新可拖到 30 秒以上。合并为单条命令后，
    /// 每次刷新只有一次远程往返（控制通道存活时约百毫秒级）。
    private static let probeScript = """
    uname -s
    probe() {
      p=""
      for c in "/opt/homebrew/bin/$1" "/usr/local/bin/$1" "/opt/local/bin/$1" "$HOME/.cargo/bin/$1"; do
        if [ -x "$c" ]; then p="$c"; break; fi
      done
      if [ -z "$p" ]; then p=$(command -v "$1" 2>/dev/null); fi
      if [ -z "$p" ] && [ -n "$SHELL" ]; then p=$("$SHELL" -l -c "command -v $1" 2>/dev/null | head -n 1); fi
      printf 'PATH:%s:%s\\n' "$1" "$p"
      if [ -n "$p" ]; then
        printf 'BEGIN:%s\\n' "$1"
        case "$1" in
          tmux|rmux) "$p" list-sessions -F '#S' 2>/dev/null ;;
          zellij) "$p" list-sessions 2>/dev/null ;;
        esac
        printf 'END:%s\\n' "$1"
      fi
    }
    probe tmux
    probe rmux
    probe zellij
    """

    /// 执行探测脚本并解析结果；失败返回 nil（调用方保留旧数据）。
    private func fetchSnapshot() async -> Snapshot? {
        do {
            let output: String
            if let connection {
                output = try await SSHCommandExecutor.shared.execute(
                    remoteCommand: Self.probeScript,
                    connection: connection
                )
            } else {
                output = try await ProcessRunner.run(shellCommand: Self.probeScript)
            }
            return parseSnapshot(output)
        } catch {
            return nil
        }
    }

    /// 解析探测脚本输出。只认行首标记（PATH:/BEGIN:/END:）与整行 OS 名，
    /// 对远端 shell 在 stdout 打印的 banner 噪音有容忍度。
    private func parseSnapshot(_ output: String) -> Snapshot {
        var snapshot = Snapshot()
        var section: String?
        for line in output.components(separatedBy: "\n") {
            let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if text == "Darwin" { snapshot.hostOS = .macOS; continue }
            if text == "Linux" { snapshot.hostOS = .linux; continue }
            if text.hasPrefix("PATH:") {
                let parts = text.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "tmux": snapshot.tmuxPath = parts[2]
                case "rmux": snapshot.rmuxPath = parts[2]
                case "zellij": snapshot.zellijPath = parts[2]
                default: break
                }
                continue
            }
            if text.hasPrefix("BEGIN:") {
                section = String(text.dropFirst(6))
                continue
            }
            if text.hasPrefix("END:") {
                section = nil
                continue
            }
            guard let section, !text.isEmpty else { continue }
            switch section {
            case "tmux":
                snapshot.tmuxSessions.append(text)
            case "rmux":
                snapshot.rmuxSessions.append(text)
            case "zellij":
                // zellij list-sessions 带 ANSI 颜色与附加说明，取每行首个词。
                let cleaned = text.strippingANSISequences()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let first = cleaned.split(separator: " ", omittingEmptySubsequences: true).first {
                    snapshot.zellijSessions.append(String(first))
                }
            default:
                break
            }
        }
        return snapshot
    }

    private func currentOS() -> HostOS {
        hostOS ?? .linux
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

    // rmux 与 tmux 使用相同的命令行参数，仅可执行文件名不同。
    private func rmuxNewSessionCommand(name: String) -> String {
        let escaped = name.singleQuotedShellArgument()
        return "rmux new -s \(escaped)"
    }

    private func rmuxAttachCommand(session: String) -> String {
        let escaped = session.singleQuotedShellArgument()
        return "if [ -n \"$TMUX$RMUX\" ]; then rmux switch-client -t \(escaped); else rmux attach-session -t \(escaped); fi"
    }

    private func rmuxKillSessionCommand(session: String) -> String {
        let escaped = session.singleQuotedShellArgument()
        return "rmux kill-session -t \(escaped)"
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
            title: L("New %@ Session", type.displayName),
            message: L("Enter %@ session name", type.displayName),
            placeholder: "Session name".localized,
            confirmTitle: "Confirm".localized,
            cancelTitle: "Cancel".localized,
            filter: { text in
                // tmux/rmux/zellij 会话名仅允许英文和数字。
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
        case .rmux:
            sendToTerminal(rmuxNewSessionCommand(name: trimmed))
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

    // rmux 的 detach 前缀与 tmux 相同（Ctrl-b d）。
    @MainActor
    func detachRmux() {
        detachTmux()
    }

    @MainActor
    func attachRmux(session: String) {
        sendToTerminal(rmuxAttachCommand(session: session))
    }

    @MainActor
    func killRmux(session: String) {
        sendToTerminal(rmuxKillSessionCommand(session: session))
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
    @Environment(\.appTheme) private var appTheme

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
        if viewModel.isLoading && !viewModel.tmuxInstalled && !viewModel.rmuxInstalled && !viewModel.zellijInstalled {
            Spacer()
            ProgressView()
            Spacer()
        } else if !viewModel.tmuxInstalled && !viewModel.rmuxInstalled && !viewModel.zellijInstalled {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 32))
                    .foregroundColor(appTheme.secondaryForeground)
                Text("Please install tmux, rmux or zellij".localized)
                    .font(.system(size: 13))
                    .foregroundColor(appTheme.secondaryForeground)
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
                            newLabel: "New tmux Session".localized,
                            newAction: { viewModel.promptNewSession(type: .tmux) },
                            detachLabel: "Detach from Current Session".localized,
                            detachAction: { viewModel.detachTmux() },
                            sessions: viewModel.tmuxSessions,
                            attachAction: { viewModel.attachTmux(session: $0) }
                        )

                        if viewModel.rmuxInstalled || viewModel.zellijInstalled {
                            Divider()
                                .padding(.horizontal, 8)
                        }
                    }

                    if viewModel.rmuxInstalled {
                        sessionSection(
                            type: .rmux,
                            title: "rmux",
                            icon: "rectangle.split.2x1",
                            newLabel: "New rmux Session".localized,
                            newAction: { viewModel.promptNewSession(type: .rmux) },
                            detachLabel: "Detach from Current Session".localized,
                            detachAction: { viewModel.detachRmux() },
                            sessions: viewModel.rmuxSessions,
                            attachAction: { viewModel.attachRmux(session: $0) }
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
                            newLabel: "New zellij Session".localized,
                            newAction: { viewModel.promptNewSession(type: .zellij) },
                            detachLabel: "Detach from Current Session".localized,
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
            title: Text(L("Delete %@ Session", item.type.displayName)),
            message: Text(L("Are you sure you want to delete session \"%@\"? This action cannot be undone.", item.name)),
            primaryButton: .destructive(Text("Delete".localized)) {
                switch item.type {
                case .tmux: viewModel.killTmux(session: item.name)
                case .rmux: viewModel.killRmux(session: item.name)
                case .zellij: viewModel.killZellij(session: item.name)
                }
            },
            secondaryButton: .cancel(Text("Cancel".localized))
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
                    .foregroundStyle(appTheme.secondaryForeground)
                    .frame(width: 18)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(appTheme.foreground)

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
            .background(appTheme.controlBackground)
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.top, 6)

            if sessions.isEmpty {
                HStack {
                    Text("No Sessions".localized)
                        .font(.system(size: 12))
                        .foregroundColor(appTheme.secondaryForeground)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                ForEach(sessions, id: \.self) { session in
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 11))
                            .foregroundColor(appTheme.secondaryForeground)
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
                        Button("Connect".localized) {
                            attachAction(session)
                        }
                        Divider()
                        Button(role: .destructive) {
                            viewModel.deleteConfirmation = DeleteConfirmation(type: type, name: session)
                        } label: {
                            Text("Delete".localized)
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
