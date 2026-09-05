import AppKit
import SwiftUI

/// Docker 面板状态。
private enum DockerPanelState {
    case checking
    case notInstalled
    case permissionDenied
    case ready
}

/// 面板内的列表分类。
private enum DockerTab: String, CaseIterable, Identifiable {
    case containers
    case images
    case volumes
    case networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: return "Containers".localized
        case .images:     return "Images".localized
        case .volumes:    return "Volumes".localized
        case .networks:   return "Networks".localized
        }
    }
}

/// 右侧栏“Docker 管理”功能面板：本地终端管理本机 Docker，SSH 终端管理远程主机 Docker。
struct DockerPanelView: View {
    let terminalController: TerminalController?

    @StateObject private var store: DockerService
    @State private var state: DockerPanelState = .checking
    @State private var tab: DockerTab = .containers
    @Environment(\.appTheme) private var appTheme

    init(terminalController: TerminalController?) {
        self.terminalController = terminalController
        _store = StateObject(wrappedValue: DockerService(connection: terminalController?.sshConnection))
    }

    var body: some View {
        Group {
            switch state {
            case .checking:
                ProgressView()
                    .scaleEffect(0.8)
            case .notInstalled:
                notInstalledView
            case .permissionDenied:
                permissionDeniedView
            case .ready:
                contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startService()
        }
    }

    // MARK: - 启动

    private func startService() {
        guard state == .checking else { return }
        Task {
            let access = await store.checkDockerAccess()
            await MainActor.run {
                switch access {
                case .ok, .unavailable:
                    // unavailable（如 daemon 未运行）沿用就绪态，由列表加载时的内联错误提示原因。
                    state = .ready
                case .cliMissing:
                    state = .notInstalled
                case .permissionDenied:
                    state = .permissionDenied
                }
            }
            switch access {
            case .ok, .unavailable:
                await store.refreshContainers()
                await store.refreshImages()
                await store.refreshVolumes()
                await store.refreshNetworks()
            case .cliMissing, .permissionDenied:
                return
            }
        }
    }

    // MARK: - 未安装提示

    private var notInstalledView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundColor(appTheme.secondaryForeground)
            Text("Docker not installed".localized)
                .font(.system(size: 14, weight: .medium))
            Text("Docker Management requires the docker CLI to be installed".localized)
                .font(.system(size: 12))
                .foregroundColor(appTheme.secondaryForeground)
                .multilineTextAlignment(.center)
            Button("Go to Install".localized) {
                if let url = URL(string: "https://www.docker.com/get-started/") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 权限不足引导

    /// 无权限访问 Docker daemon 时，引导用户把账号加入 docker 用户组（而非使用 sudo）。
    private var permissionDeniedView: some View {
        let username = store.connection?.username ?? NSUserName()
        let command = "sudo usermod -aG docker \(username)"
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundColor(appTheme.secondaryForeground)
            Text("Docker permission denied".localized)
                .font(.system(size: 14, weight: .medium))
            Text("The current user cannot access the Docker daemon. Add the user to the docker group (recommended over sudo):".localized)
                .font(.system(size: 12))
                .foregroundColor(appTheme.secondaryForeground)
                .multilineTextAlignment(.center)
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(appTheme.controlBackground.opacity(0.6))
                .cornerRadius(6)
            Text("Then log out and log back in (or reconnect) for the change to take effect.".localized)
                .font(.system(size: 12))
                .foregroundColor(appTheme.secondaryForeground)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Copy".localized) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Button("Retry".localized) {
                    state = .checking
                    startService()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 内容

    private var contentView: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            // 加载失败且当前列表为空时，以简化文案占据内容区；
            // 否则列表照常显示，问题以底部提示条呈现（不使用红色错误文案）。
            if store.issue != nil, currentListIsEmpty {
                issueView
            } else {
                switch tab {
                case .containers:
                    if store.containers.isEmpty {
                        emptyView("No containers".localized)
                    } else {
                        containerList
                    }
                case .images:
                    if store.images.isEmpty {
                        emptyView("No images".localized)
                    } else {
                        imageList
                    }
                case .volumes:
                    if store.volumes.isEmpty {
                        emptyView("No volumes".localized)
                    } else {
                        volumeList
                    }
                case .networks:
                    if store.networks.isEmpty {
                        emptyView("No networks".localized)
                    } else {
                        networkList
                    }
                }
                // 操作类失败保留原始错误信息；加载类失败显示简化文案。
                if let actionError = store.actionError {
                    Divider()
                    actionErrorBanner(actionError)
                } else if store.issue != nil {
                    Divider()
                    issueBanner
                }
            }
        }
    }

    private var currentListIsEmpty: Bool {
        switch tab {
        case .containers: return store.containers.isEmpty
        case .images:     return store.images.isEmpty
        case .volumes:    return store.volumes.isEmpty
        case .networks:   return store.networks.isEmpty
        }
    }

    // MARK: - 问题展示

    /// 加载类异常统一简化为一句话提示，不展示解决方案。
    private var issueMessage: String {
        "Please install or start the Docker service".localized
    }

    /// 列表为空时的整页问题视图（仅提示语；刷新统一使用面板右上角的刷新按钮，
    /// 刷新开始时 issue 会被清除）。
    private var issueView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(appTheme.secondaryForeground)
            Text(issueMessage)
                .font(.system(size: 13))
                .foregroundColor(appTheme.secondaryForeground)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// 列表非空时的底部问题提示条（灰色卡片，可关闭，不使用红色错误样式）。
    private var issueBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Text(issueMessage)
                .font(.system(size: 11))
                .foregroundColor(appTheme.secondaryForeground)
            Spacer()
            Button(action: { store.dismissIssue() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(appTheme.secondaryForeground)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close".localized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 操作类失败的底部提示条：保留原始错误信息。
    private func actionErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(appTheme.secondaryForeground)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            Button(action: { store.dismissActionError() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(appTheme.secondaryForeground)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close".localized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(DockerTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            Button(action: refreshCurrentTab) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .disabled(store.isLoading)
            .help("Refresh".localized)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func refreshCurrentTab() {
        Task {
            switch tab {
            case .containers: await store.refreshContainers()
            case .images:     await store.refreshImages()
            case .volumes:    await store.refreshVolumes()
            case .networks:   await store.refreshNetworks()
            }
        }
    }

    private func emptyView(_ text: String) -> some View {
        VStack {
            Spacer()
            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(appTheme.secondaryForeground)
            }
            Spacer()
        }
    }

    // MARK: - 容器列表

    private var containerList: some View {
        List {
            ForEach(store.containers) { container in
                containerRow(container)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func containerRow(_ container: DockerContainer) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(container.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(container.names)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(container.image)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(appTheme.secondaryForeground)
                    .lineLimit(1)
                Text(container.status)
                    .font(.system(size: 11))
                    .foregroundColor(appTheme.secondaryForeground)
                    .lineLimit(1)
                // 端口与挂载点一行一个完整展示，行高随数量自适应。
                if !container.ports.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(container.ports, id: \.self) { port in
                            Text(port)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(appTheme.secondaryForeground)
                                .lineLimit(1)
                        }
                    }
                }
                if !container.mounts.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(container.mounts, id: \.self) { mount in
                            Text(mount)
                                .font(.system(size: 11))
                                .foregroundColor(appTheme.secondaryForeground)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if container.isRunning {
                    actionButton(icon: "stop.fill", help: "Stop".localized) {
                        performContainerAction(.stop, container: container)
                    }
                    actionButton(icon: "arrow.counterclockwise", help: "Restart".localized) {
                        performContainerAction(.restart, container: container)
                    }
                } else {
                    actionButton(icon: "play.fill", help: "Start".localized) {
                        performContainerAction(.start, container: container)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("View Logs".localized) { showLogsWindow(container) }
            Button("View Start Command".localized) { showRunCommandWindow(container) }
            Button("Copy Info".localized) { copyContainerInfo(container) }
            Divider()
            Button("Open Terminal in Container".localized) { execIntoContainer(container) }
                .disabled(!container.isRunning)
            Divider()
            Button(role: .destructive) {
                confirmRemoveContainer(container)
            } label: {
                Text("Remove".localized)
                    .foregroundColor(.red)
            }
        }
    }

    /// 复制容器完整信息（名称、ID、镜像、状态、端口、挂载点）到剪贴板。
    private func copyContainerInfo(_ container: DockerContainer) {
        var lines: [String] = [
            "\("Name".localized): \(container.names)",
            "ID: \(container.id)",
            "\("Image".localized): \(container.image)",
            "\("Status".localized): \(container.status)",
        ]
        if !container.ports.isEmpty {
            lines.append("\("Ports".localized):")
            lines += container.ports.map { "  \($0)" }
        }
        if !container.mounts.isEmpty {
            lines.append("\("Mounts".localized):")
            lines += container.mounts.map { "  \($0)" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// 弹出非模态、永远在最前的日志窗口，日志实时刷新。
    private func showLogsWindow(_ container: DockerContainer) {
        DockerLogsWindowManager.show(
            connection: store.connection,
            container: container,
            config: terminalController?.ghostty.config,
            parentWindow: terminalController?.window
        )
    }

    /// 弹出模态窗口展示重建的 docker run 启动命令。
    private func showRunCommandWindow(_ container: DockerContainer) {
        DockerRunCommandWindowManager.show(
            store: store,
            container: container,
            config: terminalController?.ghostty.config,
            parentWindow: terminalController?.window
        )
    }

    /// 在当前终端里执行 `docker exec -it <id> sh` 进入容器；
    /// SSH 终端的 surface 本身就是远程会话，命令自然在远程主机上执行。
    private func execIntoContainer(_ container: DockerContainer) {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else { return }
        surface.sendText("docker exec -it \(container.id) sh")
        surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press, text: "\r"))
    }

    // MARK: - 镜像列表

    private var imageList: some View {
        List {
            ForEach(store.images) { image in
                imageRow(image)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func imageRow(_ image: DockerImage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(image.repository):\(image.tag)")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(image.imageID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(appTheme.secondaryForeground)
                        .lineLimit(1)
                    Text(image.size)
                        .font(.system(size: 11))
                        .foregroundColor(appTheme.secondaryForeground)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                confirmRemoveImage(image)
            } label: {
                Text("Remove".localized)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - 卷列表

    private var volumeList: some View {
        List {
            ForEach(store.volumes) { volume in
                volumeRow(volume)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func volumeRow(_ volume: DockerVolume) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(volume.driver)
                        .font(.system(size: 11))
                        .foregroundColor(appTheme.secondaryForeground)
                    Text(volume.scope)
                        .font(.system(size: 11))
                        .foregroundColor(appTheme.secondaryForeground)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 网络列表

    private var networkList: some View {
        List {
            ForEach(store.networks) { network in
                networkRow(network)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func networkRow(_ network: DockerNetwork) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(network.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(network.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(appTheme.secondaryForeground)
                    Text(network.driver)
                        .font(.system(size: 11))
                        .foregroundColor(appTheme.secondaryForeground)
                    Text(network.scope)
                        .font(.system(size: 11))
                        .foregroundColor(appTheme.secondaryForeground)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 操作

    private func actionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(appTheme.secondaryForeground)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func performContainerAction(_ action: DockerService.ContainerAction, container: DockerContainer) {
        Task {
            await store.performContainerAction(action, id: container.id)
            await store.refreshContainers()
        }
    }

    private func confirmRemoveContainer(_ container: DockerContainer) {
        confirm(
            title: "Remove Container".localized,
            message: L("Are you sure you want to remove container \"%@\"?", container.names)
        ) {
            Task {
                await store.performContainerAction(.remove, id: container.id)
                await store.refreshContainers()
            }
        }
    }

    private func confirmRemoveImage(_ image: DockerImage) {
        confirm(
            title: "Remove Image".localized,
            message: L("Are you sure you want to remove image \"%@:%@\"?", image.repository, image.tag)
        ) {
            Task {
                await store.removeImage(reference: image.reference)
                await store.refreshImages()
            }
        }
    }

    /// 弹出确认对话框（优先作为窗口 sheet），确认后执行 `proceed`。
    private func confirm(title: String, message: String, proceed: @escaping () -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK".localized)
            alert.addButton(withTitle: "Cancel".localized)
            alert.buttons.first?.hasDestructiveAction = true

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn { proceed() }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                proceed()
            }
        }
    }
}
