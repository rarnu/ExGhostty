import AppKit
import SwiftUI
import Combine

/// SFTP 面板的视图模型。
final class SFTPPanelViewModel: ObservableObject {
    let connection: SSHConnection
    weak var terminalController: TerminalController?

    @Published var currentPath: String = ""
    @Published var items: [SFTPFileItem] = []
    @Published var showHidden: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var selectedItems: Set<UUID> = [] {
        didSet { enforceSelectionRules() }
    }
    @Published var activeUploadCount: Int = 0
    @Published var activeDownloadCount: Int = 0
    weak var taskListWindowController: SFTPTaskListWindowController?

    private var cancellables = Set<AnyCancellable>()
    /// 远端用户主目录，用于把标题中的 `~` 展开为绝对路径。
    private var remoteHomeDirectory: String?
    /// 目录内容定时刷新器，用于同步终端中 rm/mv/mkdir/touch 等引起的变化。
    private var refreshTimer: Timer?

    init(connection: SSHConnection, terminalController: TerminalController?) {
        self.connection = connection
        self.terminalController = terminalController
        self.currentPath = terminalController?.currentDirectoryURL?.path
            ?? "/home/\(connection.username)"

        // 终端通过 OSC 7 上报当前目录（需要远端 shell 启用了 Ghostty shell integration）。
        terminalController?.$currentDirectoryURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, let path = url?.path, path != self.currentPath else { return }
                self.currentPath = path
                self.refresh()
            }
            .store(in: &cancellables)

        // 若 OSC 7 不可用，尝试从标题栏回推当前目录（Ghostty integration 的 title 特征为 \w）。
        terminalController?.$focusedSurfaceRawTitle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self, let title else { return }
                self.applyTitleDerivedPath(title)
            }
            .store(in: &cancellables)

        SFTPTransferManager.shared.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                guard let self else { return }
                self.updateTaskCounts(from: tasks)
            }
            .store(in: &cancellables)

        updateTaskCounts(from: SFTPTransferManager.shared.tasks)
        fetchRemoteHomeDirectory()
        startRefreshTimer()
        refresh()
    }

    deinit {
        stopRefreshTimer()
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 从标题栏文本推导绝对路径并应用。Ghostty bash integration 的 title 使用 \w，会显示为
    /// `~` 或 `/home/user/...` 形式；仅当标题看起来像路径时才使用，避免命令名误识别。
    private func applyTitleDerivedPath(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let path: String?
        // 优先处理以 `~` 开头的路径（含 `user@host:~/path` 这种前缀）。
        if let tildeRange = trimmed.range(of: "~") {
            let suffix = String(trimmed[tildeRange.lowerBound...])
            let rest = String(suffix.dropFirst())
            let home = remoteHomeDirectory ?? "/home/\(connection.username)"
            path = rest.isEmpty ? home : (home + rest)
        } else if let slashRange = trimmed.range(of: "/") {
            // 提取第一个 `/` 开始的后缀，如 `user@host:/path` → `/path`。
            path = String(trimmed[slashRange.lowerBound...])
        } else {
            path = nil
        }

        guard let path, path != currentPath else { return }
        currentPath = path
        refresh()
    }

    /// 获取远端用户主目录，用于标题中 `~` 的展开。
    private func fetchRemoteHomeDirectory() {
        Task {
            do {
                let home = try await SFTPService.shared.currentRemoteDirectory(connection: connection)
                await MainActor.run {
                    self.remoteHomeDirectory = home
                }
            } catch {
                // 失败时使用默认 /home/username
            }
        }
    }

    private func updateTaskCounts(from tasks: [SFTPTask]) {
        let connectionTasks = tasks.filter { $0.connection.id == self.connection.id }
        let newUploadCount = connectionTasks.filter { $0.type == .upload && $0.isActive }.count
        self.activeDownloadCount = connectionTasks.filter { $0.type == .download && $0.isActive }.count

        // 上传任务数从大于 0 变少，说明有上传完成，刷新当前目录以显示新文件。
        if newUploadCount < self.activeUploadCount && self.activeUploadCount > 0 {
            self.refresh()
        }
        self.activeUploadCount = newUploadCount
    }

    // MARK: - 导航

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        // 刷新前记录已选中的文件名，刷新后按文件名恢复勾选状态。
        let previouslySelectedNames = Set(self.items.filter { selectedItems.contains($0.id) }.map { $0.name })
        Task {
            do {
                let list = try await SFTPService.shared.listDirectory(
                    connection: connection,
                    path: currentPath,
                    showHidden: showHidden
                )
                await MainActor.run {
                    self.items = list.sorted {
                        if $0.isDirectory != $1.isDirectory {
                            return $0.isDirectory && !$1.isDirectory
                        }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    self.selectedItems = Set(self.items.filter { previouslySelectedNames.contains($0.name) }.map { $0.id })
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func goUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        guard parent != currentPath else { return }
        currentPath = parent
        selectedItems.removeAll()
        refresh()
    }

    func enterDirectory(_ item: SFTPFileItem) {
        guard item.isDirectory else { return }
        currentPath = currentPath + "/" + item.name
        selectedItems.removeAll()
        refresh()
    }

    func toggleHidden() {
        showHidden.toggle()
        refresh()
    }

    // MARK: - 选择规则

    // MARK: - 选择

    private func enforceSelectionRules() {
        let selectedObjects = items.filter { selectedItems.contains($0.id) }
        let hasDirectory = selectedObjects.contains { $0.isDirectory }
        if hasDirectory && selectedObjects.count > 1 {
            // 目录只能单选
            if let dir = selectedObjects.first(where: { $0.isDirectory }) {
                selectedItems = [dir.id]
            }
        }
    }

    func toggleSelection(_ item: SFTPFileItem) {
        guard !item.isDirectory else { return }
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            // 如果当前选中了目录，先清除，再改为选中该文件。
            if selectedItems.contains(where: { id in items.first { $0.id == id }?.isDirectory ?? false }) {
                selectedItems.removeAll()
            }
            selectedItems.insert(item.id)
        }
    }

    // MARK: - 上传

    func uploadFiles(_ urls: [URL]) {
        for url in urls {
            let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            let task = SFTPTask(
                type: .upload,
                localPath: url.path,
                remotePath: currentPath,
                title: url.lastPathComponent,
                connection: connection,
                isDirectory: false,
                fileSize: size
            )
            SFTPTransferManager.shared.addTask(task)
        }
    }

    func uploadFolder(_ url: URL) {
        let task = SFTPTask(
            type: .upload,
            localPath: url.path,
            remotePath: currentPath,
            title: url.lastPathComponent,
            connection: connection,
            isDirectory: true
        )
        SFTPTransferManager.shared.addTask(task)
    }

    // MARK: - 下载

    func downloadSelected() {
        let selectedObjects = items.filter { selectedItems.contains($0.id) }
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

        for item in selectedObjects {
            let remotePath = currentPath + "/" + item.name
            let task = SFTPTask(
                type: .download,
                localPath: downloadsURL.path,
                remotePath: remotePath,
                title: item.name,
                connection: connection,
                isDirectory: item.isDirectory,
                fileSize: item.size
            )
            SFTPTransferManager.shared.addTask(task)
        }
        selectedItems.removeAll()
    }

    // MARK: - 删除

    func delete(item: SFTPFileItem) async {
        let remotePath = currentPath + "/" + item.name
        do {
            if item.isDirectory {
                try await SFTPService.shared.deleteDirectory(connection: connection, remotePath: remotePath)
            } else {
                try await SFTPService.shared.deleteFile(connection: connection, remotePath: remotePath)
            }
            await MainActor.run {
                self.selectedItems.remove(item.id)
                self.refresh()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func deleteSelected() async {
        let selectedObjects = items.filter { selectedItems.contains($0.id) }
        guard !selectedObjects.isEmpty else { return }

        for item in selectedObjects {
            let remotePath = currentPath + "/" + item.name
            do {
                if item.isDirectory {
                    try await SFTPService.shared.deleteDirectory(connection: connection, remotePath: remotePath)
                } else {
                    try await SFTPService.shared.deleteFile(connection: connection, remotePath: remotePath)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
                return
            }
        }
        await MainActor.run {
            self.selectedItems.removeAll()
            self.refresh()
        }
    }

    var hasSelection: Bool { !selectedItems.isEmpty }

    var selectedCanDownload: Bool {
        let selectedObjects = items.filter { selectedItems.contains($0.id) }
        return !selectedObjects.isEmpty
    }

    // MARK: - 重命名

    func rename(item: SFTPFileItem, to newName: String) async {
        let oldPath = currentPath + "/" + item.name
        let newPath = currentPath + "/" + newName
        do {
            try await SFTPService.shared.rename(
                connection: connection,
                from: oldPath,
                to: newPath
            )
            await MainActor.run {
                self.selectedItems.remove(item.id)
                self.refresh()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 任务窗口

    func openTaskListWindow() {
        if let existing = taskListWindowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let config = terminalController?.ghostty.config
        let controller = SFTPTaskListWindowController(
            connection: connection,
            config: config,
            parentWindow: terminalController?.window,
            onWindowClosed: { [weak self] in
                self?.taskListWindowController = nil
            }
        )
        controller.showWindow(nil)
        taskListWindowController = controller
    }
}

/// SFTP 功能主界面。
struct SFTPPanelView: View {
    @StateObject private var viewModel: SFTPPanelViewModel

    init(connection: SSHConnection, terminalController: TerminalController?) {
        _viewModel = StateObject(wrappedValue: SFTPPanelViewModel(
            connection: connection,
            terminalController: terminalController
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            toolbar
            taskStatusBar
            fileList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 路径栏

    private var pathBar: some View {
        HStack {
            Text(viewModel.currentPath)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.controlBackgroundColor).opacity(0.3))
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolbarButton(icon: "arrow.up", label: "上级") { viewModel.goUp() }
            toolbarButton(icon: "arrow.clockwise", label: "刷新") { viewModel.refresh() }
            toolbarButton(
                icon: viewModel.showHidden ? "eye" : "eye.slash",
                label: viewModel.showHidden ? "隐藏隐藏内容" : "显示隐藏内容"
            ) { viewModel.toggleHidden() }

            Divider().frame(height: 20)

            toolbarButton(icon: "arrow.up.doc", label: "上传文件") { uploadFiles() }
            toolbarButton(icon: "arrow.up.folder", label: "上传文件夹") { uploadFolder() }

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 8))
            }
            .foregroundColor(.secondary)
            .frame(width: 38, height: 30)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - 任务状态栏

    private var taskStatusBar: some View {
        let uploadCount = viewModel.activeUploadCount
        let downloadCount = viewModel.activeDownloadCount

        return HStack {
            Text("上传任务: \(uploadCount) 个，下载任务: \(downloadCount) 个")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Button("详情") { viewModel.openTaskListWindow() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                // 增大可点击区域，让按钮更容易点中。
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.2))
    }

    // MARK: - 文件列表

    private var fileList: some View {
        Group {
            if let error = viewModel.errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
            } else {
                List(selection: $viewModel.selectedItems) {
                    ForEach(viewModel.items) { item in
                        fileRow(item: item)
                            .tag(item.id)
                            .contextMenu {
                                downloadContextMenu(item: item)
                                if viewModel.selectedItems.count <= 1 {
                                    Button("重命名") {
                                        confirmRename(item: item)
                                    }
                                }
                                if viewModel.selectedItems.count > 1 && viewModel.selectedItems.contains(item.id) {
                                    Button("删除这些文件") {
                                        confirmDeleteSelected()
                                    }
                                } else {
                                    Button("删除") {
                                        confirmDelete(item: item)
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func fileRow(item: SFTPFileItem) -> some View {
        HStack(spacing: 6) {
            if item.isDirectory {
                // 目录不显示复选框，用透明占位保持对齐。
                Color.clear.frame(width: 18)
            } else {
                Button(action: { viewModel.toggleSelection(item) }) {
                    Image(systemName: viewModel.selectedItems.contains(item.id) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundColor(viewModel.selectedItems.contains(item.id) ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 18)
            }

            Image(systemName: item.isDirectory ? "folder" : "doc")
                .font(.system(size: 14))
                .foregroundColor(item.isDirectory ? .accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let size = item.size, !item.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory {
                viewModel.enterDirectory(item)
            }
        }
    }

    /// 根据当前选中状态生成右键下载菜单。
    @ViewBuilder
    private func downloadContextMenu(item: SFTPFileItem) -> some View {
        let selectedCount = viewModel.selectedItems.count
        let isSelected = viewModel.selectedItems.contains(item.id)

        if selectedCount > 1 && isSelected {
            Button("下载这些文件") {
                viewModel.downloadSelected()
                viewModel.selectedItems.removeAll()
            }
        } else {
            Button("下载这个\(item.isDirectory ? "目录" : "文件")") {
                download(item: item)
                viewModel.selectedItems.removeAll()
            }
        }
    }

    // MARK: - 操作

    private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { result in
            if result == .OK {
                viewModel.uploadFiles(panel.urls)
            }
        }
    }

    private func uploadFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { result in
            if result == .OK, let url = panel.url {
                viewModel.uploadFolder(url)
            }
        }
    }

    private func download(item: SFTPFileItem) {
        viewModel.selectedItems = [item.id]
        viewModel.downloadSelected()
    }

    private func confirmDelete(item: SFTPFileItem) {
        let alert = NSAlert()
        alert.messageText = "确认删除"
        alert.informativeText = "确定要删除\(item.isDirectory ? "目录" : "文件") “\(item.name)” 吗？此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
            if response == .alertFirstButtonReturn {
                Task {
                    await self.viewModel.delete(item: item)
                }
            }
        }
    }

    private func confirmDeleteSelected() {
        let selectedObjects = viewModel.items.filter { viewModel.selectedItems.contains($0.id) }
        guard selectedObjects.count > 1 else {
            if let first = selectedObjects.first {
                confirmDelete(item: first)
            }
            return
        }

        let names = selectedObjects.map { "• \($0.name)" }.joined(separator: "\n")
        let hasDirectory = selectedObjects.contains { $0.isDirectory }
        let typeText = hasDirectory ? "项目" : "文件"

        let alert = NSAlert()
        alert.messageText = "确认删除 \(selectedObjects.count) 个\(typeText)"
        alert.informativeText = "确定要删除以下\(typeText)吗？此操作不可撤销。\n\n\(names)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
            if response == .alertFirstButtonReturn {
                Task {
                    await self.viewModel.deleteSelected()
                }
            }
        }
    }

    private func confirmRename(item: SFTPFileItem) {
        let alert = NSAlert()
        alert.messageText = "重命名\(item.isDirectory ? "目录" : "文件")"
        alert.informativeText = "请输入新的名称："
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        textField.stringValue = item.name
        textField.selectText(nil)
        alert.accessoryView = textField

        alert.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
            if response == .alertFirstButtonReturn {
                let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty, newName != item.name else { return }
                Task {
                    await self.viewModel.rename(item: item, to: newName)
                }
            }
        }
    }
}
