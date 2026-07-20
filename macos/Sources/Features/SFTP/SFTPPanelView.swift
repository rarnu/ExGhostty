import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// SFTP 面板的视图模型。
final class SFTPPanelViewModel: ObservableObject {
    let connection: SSHConnection
    weak var terminalController: TerminalController?

    @Published var currentPath: String = ""
    @Published var items: [SFTPFileItem] = []
    @Published var showHidden: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var selectedItems: Set<UUID> = []
    @Published var activeUploadCount: Int = 0
    @Published var activeDownloadCount: Int = 0
    /// 上一级目录对当前用户是否可写，决定是否显示"移动到上一级"菜单项。
    @Published var parentIsWritable: Bool = false
    weak var taskListWindowController: SFTPTaskListWindowController?

    private var cancellables = Set<AnyCancellable>()
    /// 任务状态订阅（任务数组本身只在增删时发布，状态变化需单独订阅）。
    private var taskStateCancellables = Set<AnyCancellable>()
    /// 远端用户主目录，用于把标题中的 `~` 展开为绝对路径。
    private var remoteHomeDirectory: String?
    /// 根据用户名推断的默认远端主目录。root 用户为 /root，其他用户为 /home/<username>。
    private var defaultHomeDirectory: String {
        connection.username == "root" ? "/root" : "/home/\(connection.username)"
    }
    init(connection: SSHConnection, terminalController: TerminalController?) {
        self.connection = connection
        self.terminalController = terminalController
        self.currentPath = terminalController?.currentDirectoryURL?.path
            ?? defaultHomeDirectory

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
                self.observeTaskStates(tasks)
            }
            .store(in: &cancellables)

        updateTaskCounts(from: SFTPTransferManager.shared.tasks)
        observeTaskStates(SFTPTransferManager.shared.tasks)
        fetchRemoteHomeDirectory()
        refresh()
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
            let home = remoteHomeDirectory ?? defaultHomeDirectory
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
                    // 如果当前路径仍停留在默认的 /home/<user>（对 root 是 /home/root，
                    // 但实际不存在），则用真实的 home 目录修正。
                    if self.currentPath == self.defaultHomeDirectory && self.currentPath != home {
                        self.currentPath = home
                        self.refresh()
                    }
                }
            } catch {
                // 失败时使用默认 home
            }
        }
    }

    /// 订阅每个任务的状态变化。`SFTPTransferManager.$tasks` 只在任务增删时发布，
    /// 任务完成/失败不会触发；不订阅状态的话，上传完毕后计数不更新、目录也不刷新。
    private func observeTaskStates(_ tasks: [SFTPTask]) {
        taskStateCancellables.removeAll()
        for task in tasks where task.connection.id == connection.id {
            task.$state
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.updateTaskCounts(from: SFTPTransferManager.shared.tasks)
                }
                .store(in: &taskStateCancellables)
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

    /// 上一级目录路径；当前位于根目录时为 nil。
    var parentPath: String? {
        let parent = (currentPath as NSString).deletingLastPathComponent
        return parent == currentPath ? nil : parent
    }

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
                // 顺带检查上一级目录是否可写，用于"移动到上一级"菜单项的显隐。
                let writable: Bool
                if let parent = self.parentPath {
                    writable = await SFTPService.shared.isWritable(connection: self.connection, path: parent)
                } else {
                    writable = false
                }
                await MainActor.run {
                    self.items = list.sorted {
                        if $0.isDirectory != $1.isDirectory {
                            return $0.isDirectory && !$1.isDirectory
                        }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    self.selectedItems = Set(self.items.filter { previouslySelectedNames.contains($0.name) }.map { $0.id })
                    self.parentIsWritable = writable
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

    // MARK: - 选择

    /// 最近一次点选的条目，作为 shift 范围选择的锚点。
    private var lastSelectedID: UUID?

    func toggleSelection(_ item: SFTPFileItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
        lastSelectedID = item.id
    }

    /// 处理行点选：普通点击单选，cmd 点击切换选中，shift 点击范围选择。
    func handleRowClick(_ item: SFTPFileItem) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
        } else if modifiers.contains(.shift),
                  let anchor = lastSelectedID,
                  let anchorIndex = items.firstIndex(where: { $0.id == anchor }),
                  let targetIndex = items.firstIndex(where: { $0.id == item.id }) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedItems = Set(items[range].map { $0.id })
        } else {
            selectedItems = [item.id]
        }
        lastSelectedID = item.id
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

    // MARK: - 移动

    /// 将当前目录下的条目移动到子目录中（拖拽触发）。
    /// 若被拖拽条目处于多选集合中，则移动整个选中集合。
    func moveItem(named name: String, intoDirectory directory: SFTPFileItem) async {
        guard directory.isDirectory, name != directory.name else { return }
        let selected = items.filter { selectedItems.contains($0.id) }
        let entries: [SFTPFileItem]
        if selected.count > 1, selected.contains(where: { $0.name == name }) {
            entries = selected
        } else if let single = items.first(where: { $0.name == name }) {
            entries = [single]
        } else {
            return
        }
        for entry in entries where entry.id != directory.id {
            let source = currentPath + "/" + entry.name
            let destination = currentPath + "/" + directory.name + "/" + entry.name
            do {
                try await SFTPService.shared.rename(connection: connection, from: source, to: destination)
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

    /// 将条目移动到上一级目录。
    func moveToParent(item: SFTPFileItem) async {
        guard let parent = parentPath else { return }
        let source = currentPath + "/" + item.name
        let destination = (parent as NSString).appendingPathComponent(item.name)
        await move(from: source, to: destination)
    }

    private func move(from source: String, to destination: String) async {
        do {
            try await SFTPService.shared.rename(
                connection: connection,
                from: source,
                to: destination
            )
            await MainActor.run {
                self.selectedItems.removeAll()
                self.refresh()
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 拖拽

    /// 从列表行启动 AppKit 拖拽会话：每个拖出条目一个 file promise，
    /// 拖入 Finder 后各自落地为独立的文件/目录（各生成一个下载任务）；
    /// 列表内部拖到目录行上则执行 mv。若被拖拽条目处于多选集合中，则拖出整个集合。
    func beginDragSession(for item: SFTPFileItem) {
        guard let event = NSApp.currentEvent,
              let view = event.window?.contentView ?? NSApp.keyWindow?.contentView else { return }
        let draggedItems: [SFTPFileItem]
        if selectedItems.contains(item.id), selectedItems.count > 1 {
            draggedItems = items.filter { selectedItems.contains($0.id) }
        } else {
            draggedItems = [item]
        }
        SFTPDragSession.begin(
            draggedItem: item,
            items: draggedItems,
            connection: connection,
            remoteDirectory: currentPath,
            event: event,
            view: view
        )
    }

    /// 处理从 Finder 拖入的文件/目录：为每个条目生成上传任务。
    /// directory 为拖放落点的目录行，nil 表示上传到当前目录。
    func uploadDroppedItems(_ urls: [URL], into directory: SFTPFileItem? = nil) {
        let remoteDirectory = directory.map { currentPath + "/" + $0.name } ?? currentPath
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let task = SFTPTask(
                    type: .upload,
                    localPath: url.path,
                    remotePath: remoteDirectory,
                    title: url.lastPathComponent,
                    connection: connection,
                    isDirectory: true
                )
                SFTPTransferManager.shared.addTask(task)
            } else {
                let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                let task = SFTPTask(
                    type: .upload,
                    localPath: url.path,
                    remotePath: remoteDirectory,
                    title: url.lastPathComponent,
                    connection: connection,
                    isDirectory: false,
                    fileSize: size
                )
                SFTPTransferManager.shared.addTask(task)
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
        // 从 Finder 拖入到列表空白区域（或面板其他非行区域）：上传到当前目录。
        // 注：直接挂在 SwiftUI List 上的 onDrop 无法覆盖空白区域，因此挂在外层容器。
        .onDrop(of: [.fileURL], delegate: SFTPListDropDelegate(viewModel: viewModel))
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
            toolbarButton(icon: "arrow.up", label: "Parent".localized) { viewModel.goUp() }
            toolbarButton(icon: "arrow.clockwise", label: "Refresh".localized) { viewModel.refresh() }
            toolbarButton(
                icon: viewModel.showHidden ? "eye" : "eye.slash",
                label: viewModel.showHidden ? "Hide Hidden Items".localized : "Show Hidden Items".localized
            ) { viewModel.toggleHidden() }

            Divider().frame(height: 20)

            toolbarButton(icon: "arrow.up.doc", label: "Upload File".localized) { uploadFiles() }
            toolbarButton(icon: "arrow.up.folder", label: "Upload Folder".localized) { uploadFolder() }

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
            Text(L("Upload tasks: %d, Download tasks: %d", uploadCount, downloadCount))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Button("Details".localized) { viewModel.openTaskListWindow() }
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
                // 不用 SwiftUI List：其底层 NSTableView 会拦截空白区域的拖放，
                // 导致外层 onDrop 收不到 Finder 拖入。改用 ScrollView + LazyVStack，
                // 选择逻辑由 handleRowClick 手动实现。
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.items) { item in
                            fileRow(item: item)
                                .contextMenu {
                                    downloadContextMenu(item: item)
                                    if viewModel.selectedItems.count <= 1 {
                                        // 仅当上一级目录存在且当前用户可写时，才允许移动到上一级。
                                        if viewModel.parentIsWritable, viewModel.parentPath != nil {
                                            Button("Move to Parent Directory".localized) {
                                                Task {
                                                    await viewModel.moveToParent(item: item)
                                                }
                                            }
                                        }
                                        Button("Rename".localized) {
                                            confirmRename(item: item)
                                        }
                                    }
                                    if viewModel.selectedItems.count > 1 && viewModel.selectedItems.contains(item.id) {
                                        Button(role: .destructive) {
                                            confirmDeleteSelected()
                                        } label: {
                                            Text("Delete These Files".localized)
                                                .foregroundColor(.red)
                                        }
                                    } else {
                                        Button(role: .destructive) {
                                            confirmDelete(item: item)
                                        } label: {
                                            Text("Delete".localized)
                                                .foregroundColor(.red)
                                        }
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func fileRow(item: SFTPFileItem) -> some View {
        HStack(spacing: 6) {
            Button(action: { viewModel.toggleSelection(item) }) {
                Image(systemName: viewModel.selectedItems.contains(item.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(viewModel.selectedItems.contains(item.id) ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 18)

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
        .padding(.horizontal, 4)
        .background(
            viewModel.selectedItems.contains(item.id)
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory {
                viewModel.enterDirectory(item)
            }
        }
        .onTapGesture(count: 1) {
            viewModel.handleRowClick(item)
        }
        // 拖动行时启动 AppKit 拖拽会话：拖出到 Finder 每个条目落地为独立文件/目录；
        // 列表内部拖到目录行上执行 mv；从 Finder 拖入则上传。
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global).onChanged { _ in
                viewModel.beginDragSession(for: item)
            }
        )
        .onDrop(
            of: [SFTPDragSession.internalMoveUTType, .fileURL],
            delegate: SFTPRowDropDelegate(item: item, viewModel: viewModel)
        )
    }

    /// 根据当前选中状态生成右键下载菜单。
    @ViewBuilder
    private func downloadContextMenu(item: SFTPFileItem) -> some View {
        let selectedCount = viewModel.selectedItems.count
        let isSelected = viewModel.selectedItems.contains(item.id)

        if selectedCount > 1 && isSelected {
            Button("Download These Files".localized) {
                viewModel.downloadSelected()
                viewModel.selectedItems.removeAll()
            }
        } else {
            Button(item.isDirectory ? "Download This Directory".localized : "Download This File".localized) {
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
        alert.messageText = "Confirm Delete".localized
        alert.informativeText = item.isDirectory
            ? L("Are you sure you want to delete directory \"%@\"? This action cannot be undone.", item.name)
            : L("Are you sure you want to delete file \"%@\"? This action cannot be undone.", item.name)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete".localized)
        alert.addButton(withTitle: "Cancel".localized)
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
        let typeText = hasDirectory ? "Items".localized : "File".localized

        let alert = NSAlert()
        alert.messageText = L("Confirm deletion of %d %@", selectedObjects.count, typeText)
        alert.informativeText = L("Are you sure you want to delete the following %@? This action cannot be undone.\n\n%@", typeText, names)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete".localized)
        alert.addButton(withTitle: "Cancel".localized)
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
        alert.messageText = item.isDirectory ? "Rename Directory".localized : "Rename File".localized
        alert.informativeText = "Enter new name:".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK".localized)
        alert.addButton(withTitle: "Cancel".localized)

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


// MARK: - 拖放处理

/// 从拖放内容中异步加载 Finder 文件 URL 列表。
private func loadDroppedFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        completion(urls)
    }
}

/// 列表行的拖放处理：列表内部拖拽 → 移动到该目录行；外部文件拖入 → 上传
/// （落在目录行上上传到该目录内，落在文件行上上传到当前目录）。
private struct SFTPRowDropDelegate: DropDelegate {
    let item: SFTPFileItem
    let viewModel: SFTPPanelViewModel

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [SFTPDragSession.internalMoveUTType]) {
            // 列表内部移动只接受目录行作为落点。
            return item.isDirectory
        }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        // 列表内部移动优先。
        if let provider = info.itemProviders(for: [SFTPDragSession.internalMoveUTType]).first {
            guard item.isDirectory else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: SFTPDragSession.internalMoveType.rawValue) { data, _ in
                guard let data, let name = String(data: data, encoding: .utf8) else { return }
                Task {
                    await viewModel.moveItem(named: name, intoDirectory: item)
                }
            }
            return true
        }
        return handleFileDrop(info: info, into: item.isDirectory ? item : nil)
    }

    private func handleFileDrop(info: DropInfo, into directory: SFTPFileItem?) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        loadDroppedFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            viewModel.uploadDroppedItems(urls, into: directory)
        }
        return true
    }
}

/// 列表空白区域的拖放处理：外部文件拖入 → 上传到当前目录。
private struct SFTPListDropDelegate: DropDelegate {
    let viewModel: SFTPPanelViewModel

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        loadDroppedFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            viewModel.uploadDroppedItems(urls)
        }
        return true
    }
}
