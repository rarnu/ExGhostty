//
//  SFTPPanelView.swift
//  ExGhostty_iPad
//
//  SFTP file manager panel: breadcrumb path bar, toolbar, remote file list
//  with download / rename / delete actions (swipe actions + long-press
//  context menu; tapping a file does nothing, tapping a folder enters it),
//  document-picker file/folder uploads and share-sheet downloads. Transfers
//  show a progress bar at the bottom. The context menu also opens files and
//  directories in the terminal with the configured editor (SettingsStore.
//  terminalEditor) by typing the command through TerminalBox; directories
//  download as extracted folders (remote tar + local SWCompression unpack).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SFTPPanelView: View {
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var viewModel: SFTPViewModel

    /// Live terminal controller, used to "type" the editor command into the
    /// terminal for the open-with-editor actions.
    private let terminalBox: TerminalBox
    /// Switches the session page back to the terminal panel.
    private let onOpenInTerminal: () -> Void

    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingItem: SFTPItem?
    @State private var renameText = ""
    @State private var deletingItem: SFTPItem?
    @State private var showDocumentPicker = false
    @State private var showFolderPicker = false
    @State private var shareURL: URL?

    init(session: SSHSession, terminalBox: TerminalBox, onOpenInTerminal: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: SFTPViewModel(session: session))
        self.terminalBox = terminalBox
        self.onOpenInTerminal = onOpenInTerminal
    }

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .idle, .loading:
                loadingView
            case .failed(let message):
                errorView(message)
            case .loaded:
                loadedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.open() }
        .onDisappear { viewModel.close() }
        .alert(L("新建文件夹"), isPresented: $showNewFolderAlert) {
            TextField(L("文件夹名称"), text: $newFolderName)
            Button(L("取消"), role: .cancel) { newFolderName = "" }
            Button(L("创建")) {
                let name = newFolderName
                newFolderName = ""
                Task { await viewModel.createFolder(named: name) }
            }
        }
        .alert(L("重命名"), isPresented: renamingItemBinding) {
            TextField(L("新名称"), text: $renameText)
            Button(L("取消"), role: .cancel) { renamingItem = nil }
            Button(L("确定")) {
                if let item = renamingItem {
                    renamingItem = nil
                    Task { await viewModel.rename(item, to: renameText) }
                }
            }
        }
        .alert(L("删除"), isPresented: deletingItemBinding) {
            Button(L("取消"), role: .cancel) { deletingItem = nil }
            Button(L("删除"), role: .destructive) {
                if let item = deletingItem {
                    deletingItem = nil
                    Task { await viewModel.delete(item) }
                }
            }
        } message: {
            if let item = deletingItem {
                Text(item.isDirectory
                     ? L("确定删除目录 “%@” 及其全部内容吗？", item.name)
                     : L("确定删除文件 “%@” 吗？", item.name))
            }
        }
        .alert(L("错误"), isPresented: errorBinding) {
            Button(L("确定"), role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(L(viewModel.errorMessage ?? ""))
        }
        .alert(L("%@ 未安装", editorName), isPresented: $viewModel.editorNotInstalledPending) {
            Button(L("取消"), role: .cancel) { viewModel.editorNotInstalledPending = false }
            Button(L("安装")) {
                viewModel.editorNotInstalledPending = false
                installEditor()
            }
        } message: {
            Text(L("远端机器未安装 %@。", editorName))
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(contentTypes: [.item], asCopy: true) { url in
                guard let url else { return }
                Task { await uploadPickedFile(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFolderPicker) {
            DocumentPicker(contentTypes: [.folder], asCopy: false) { url in
                guard let url else { return }
                Task { await uploadPickedFolder(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: shareSheetBinding) {
            if let shareURL {
                ShareSheet(items: [shareURL])
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.teal)
            Text(L("正在打开 SFTP 会话…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(L("SFTP 打开失败"))
                .font(.headline)
            Text(L(message))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(L("重试")) { viewModel.open() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadedView: some View {
        VStack(spacing: 0) {
            pathBar
            toolbar
            Divider()
            fileList
            if let transfer = viewModel.transfer {
                transferBar(transfer)
            }
        }
    }

    // MARK: - Path bar & toolbar

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(viewModel.breadcrumbs) { crumb in
                    if crumb.path != "/" {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        viewModel.navigate(to: crumb.path)
                    } label: {
                        Text(crumb.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(crumb.path == viewModel.currentPath ? Color.teal : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.13))
    }

    private var toolbar: some View {
        HStack(spacing: 20) {
            toolbarButton(icon: "arrow.up", help: "上级目录") {
                viewModel.goUp()
            }
            .disabled(viewModel.currentPath == "/")

            toolbarButton(icon: "arrow.clockwise", help: "刷新") {
                Task { await viewModel.refreshShowingErrors() }
            }

            toolbarButton(
                icon: viewModel.showHiddenFiles ? "eye" : "eye.slash",
                help: "显示/隐藏隐藏文件"
            ) {
                viewModel.showHiddenFiles.toggle()
            }

            toolbarButton(icon: "folder.badge.plus", help: "新建文件夹") {
                newFolderName = ""
                showNewFolderAlert = true
            }

            toolbarButton(icon: "square.and.arrow.up", help: "上传文件") {
                showDocumentPicker = true
            }

            toolbarButton(icon: "square.and.arrow.up.on.square", help: "上传目录") {
                showFolderPicker = true
            }

            Spacer()

            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.teal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(white: 0.13))
    }

    private func toolbarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.teal)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(help))
    }

    // MARK: - File list

    private var fileList: some View {
        List {
            if viewModel.visibleItems.isEmpty {
                Text(L("空目录"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.visibleItems) { item in
                    fileRow(item)
                        .contentShape(Rectangle())
                        // Tap navigates into directories only; file actions
                        // live in the swipe actions and the long-press menu.
                        .onTapGesture {
                            if item.isDirectory {
                                viewModel.navigate(to: item.path)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletingItem = item
                            } label: {
                                Label(L("删除"), systemImage: "trash")
                            }
                            Button {
                                renameText = item.name
                                renamingItem = item
                            } label: {
                                Label(L("重命名"), systemImage: "pencil")
                            }
                            .tint(.orange)
                            if !item.isDirectory {
                                Button {
                                    downloadAndShare(item)
                                } label: {
                                    Label(L("下载"), systemImage: "arrow.down.circle")
                                }
                                .tint(.teal)
                            }
                        }
                        .contextMenu {
                            if item.isDirectory {
                                Button {
                                    downloadDirectoryAndShare(item)
                                } label: {
                                    Label(L("下载目录"), systemImage: "arrow.down.circle")
                                }
                                Button {
                                    openWithEditor(item)
                                } label: {
                                    Label(L("使用 %@ 打开目录", editorName), systemImage: "square.and.pencil")
                                }
                            } else {
                                Button {
                                    downloadAndShare(item)
                                } label: {
                                    Label(L("下载"), systemImage: "arrow.down.circle")
                                }
                                Button {
                                    openWithEditor(item)
                                } label: {
                                    Label(L("使用 %@ 打开", editorName), systemImage: "square.and.pencil")
                                }
                            }
                            Button {
                                renameText = item.name
                                renamingItem = item
                            } label: {
                                Label(L("重命名"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingItem = item
                            } label: {
                                Label(L("删除"), systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await viewModel.refreshShowingErrors()
        }
    }

    private func fileRow(_ item: SFTPItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(for: item.name))
                .font(.title3)
                .foregroundStyle(item.isDirectory ? Color.teal : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if !item.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                    }
                    if let date = item.modificationDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Spacer()
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Color(white: 0.15))
    }

    private func fileIcon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "svg": return "photo"
        case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "txt", "md", "log", "json", "yaml", "yml", "xml", "conf", "sh", "py": return "doc.text"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    // MARK: - Transfer bar

    private func transferBar(_ transfer: SFTPViewModel.TransferProgress) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(transfer.title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.sent), countStyle: .file)) / \(transfer.total > 0 ? ByteCountFormatter.string(fromByteCount: Int64(transfer.total), countStyle: .file) : L("未知"))")
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if transfer.total > 0 {
                ProgressView(value: Double(transfer.sent), total: Double(transfer.total))
                    .tint(.teal)
            } else {
                ProgressView()
                    .tint(.teal)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.13))
    }

    // MARK: - Actions

    /// The configured terminal editor name, shown in the context menu and
    /// sent to the terminal by the open-with-editor actions.
    private var editorName: String {
        SettingsStore.shared.terminalEditor
    }

    private func downloadAndShare(_ item: SFTPItem) {
        Task {
            do {
                let localURL = try await viewModel.download(item)
                shareURL = localURL
            } catch {
                if !Task.isCancelled {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func downloadDirectoryAndShare(_ item: SFTPItem) {
        Task {
            do {
                let localURL = try await viewModel.downloadDirectory(item)
                shareURL = localURL
            } catch {
                if !Task.isCancelled {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Opens the file / directory in the terminal with the configured editor.
    ///
    /// 所有编辑器都先做远端安装预检查（`command -v <命令>`，一次静默 SSH，
    /// 与 Mac 版 checkEditorAndOpen 一致）：
    /// - 已安装 → 直接在终端执行 `<编辑器> <路径>`
    /// - 未安装 → 弹出「XX 未安装」提示（不含安装命令）；用户可点「安装」
    ///   在终端执行该编辑器的安装命令，安装完手动打开目标
    private func openWithEditor(_ item: SFTPItem) {
        viewModel.checkEditorAndOpen(editorName, item: item) { [self] target in
            sendEditorCommand(target)
        }
    }

    /// Types "<editor> <path>" into the terminal and switches to it.
    private func sendEditorCommand(_ item: SFTPItem) {
        guard let terminal = terminalBox.terminalView else {
            viewModel.errorMessage = "终端不可用"
            return
        }
        terminal.sendText("\(editorName) \(SFTPViewModel.shellQuote(item.path))")
        terminal.sendText("\r")
        onOpenInTerminal()
    }

    /// Runs the current editor's install command in the terminal (after user
    /// confirmation). 一次性安装，不自动打开目标（与 Mac 版 installEditor 一致）。
    private func installEditor() {
        guard let terminal = terminalBox.terminalView else {
            viewModel.errorMessage = "终端不可用"
            return
        }
        let editor = TerminalEditor(rawValue: editorName) ?? .vim
        terminal.sendText(editor.installCommand)
        terminal.sendText("\r")
        onOpenInTerminal()
    }

    private func uploadPickedFile(_ url: URL) async {
        // Copy the security-scoped pick into our temp directory first so the
        // upload does not depend on the picker keeping the file alive.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("sftp-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let localCopy = staging.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: localCopy)
            try await viewModel.upload(localURL: localCopy)
            try? FileManager.default.removeItem(at: staging)
        } catch {
            if !Task.isCancelled {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private func uploadPickedFolder(_ url: URL) async {
        // Folder picks are not copied (asCopy: false — folders cannot be
        // copied by the picker); the URL is read while packing, inside the
        // security scope's lifetime.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try await viewModel.uploadDirectory(localURL: url)
        } catch {
            if !Task.isCancelled {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Presentation bindings

    private var renamingItemBinding: Binding<Bool> {
        Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )
    }

    private var deletingItemBinding: Binding<Bool> {
        Binding(
            get: { deletingItem != nil },
            set: { if !$0 { deletingItem = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )
    }
}

// MARK: - Document picker (local file / folder upload)

/// Wraps UIDocumentPickerViewController to pick any local file or folder
/// (Files app, iCloud Drive, third-party providers) instead of PhotosPicker.
/// Folders must be picked with asCopy: false (the picker cannot copy them);
/// the returned security-scoped URL is read directly while packing.
private struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let asCopy: Bool
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: asCopy)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}

// MARK: - Share sheet (download destination)

/// Wraps UIActivityViewController so a downloaded file can be saved to
/// Files, AirDropped, or shared elsewhere.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
