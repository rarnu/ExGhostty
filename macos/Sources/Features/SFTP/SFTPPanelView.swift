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

    private var cancellables = Set<AnyCancellable>()
    /// 远端用户主目录，用于把标题中的 `~` 展开为绝对路径。
    private var remoteHomeDirectory: String?

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

    /// 手动同步终端当前目录。
    func syncWithTerminal() {
        Task {
            do {
                let remotePath = try await SFTPService.shared.currentRemoteDirectory(connection: connection)
                await MainActor.run {
                    if remotePath != self.currentPath {
                        self.currentPath = remotePath
                        self.refresh()
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateTaskCounts(from tasks: [SFTPTask]) {
        let connectionTasks = tasks.filter { $0.connection.id == self.connection.id }
        self.activeUploadCount = connectionTasks.filter { $0.type == .upload && $0.isActive }.count
        self.activeDownloadCount = connectionTasks.filter { $0.type == .download && $0.isActive }.count
    }

    // MARK: - 导航

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
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

    // MARK: - 上传

    func uploadFiles(_ urls: [URL]) {
        for url in urls {
            let task = SFTPTask(
                type: .upload,
                localPath: url.path,
                remotePath: currentPath,
                title: url.lastPathComponent,
                connection: connection,
                isDirectory: false
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
                isDirectory: item.isDirectory
            )
            SFTPTransferManager.shared.addTask(task)
        }
        selectedItems.removeAll()
    }

    var hasSelection: Bool { !selectedItems.isEmpty }

    var selectedCanDownload: Bool {
        let selectedObjects = items.filter { selectedItems.contains($0.id) }
        return !selectedObjects.isEmpty
    }
}

/// SFTP 功能主界面。
struct SFTPPanelView: View {
    @StateObject private var viewModel: SFTPPanelViewModel
    @State private var showTaskSheet = false

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
        .sheet(isPresented: $showTaskSheet) {
            SFTPTaskListView(connection: viewModel.connection)
                .frame(minWidth: 500, minHeight: 300)
        }
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
            toolbarButton(icon: "arrow.2.circlepath", label: "同步") { viewModel.syncWithTerminal() }
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
        let visible = uploadCount > 0 || downloadCount > 0

        return Group {
            if visible {
                HStack {
                    Text("上传任务: \(uploadCount) 个，下载任务: \(downloadCount) 个")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("详情") { showTaskSheet = true }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.controlBackgroundColor).opacity(0.2))
            }
        }
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
                                Button("下载\(item.isDirectory ? "目录" : "文件")") {
                                    download(item: item)
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
}
