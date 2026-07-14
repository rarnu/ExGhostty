import SwiftUI
import UniformTypeIdentifiers

// MARK: - Attach window 工具函数

extension View {
    /// 获取当前视图所在的 NSWindow
    var hostingWindow: NSWindow? {
        NSApp.keyWindow
    }
}

/// 在指定窗口上弹出一个 SwiftUI 视图作为模态窗口
func presentAsModalWindow<Content: View>(
    _ view: Content,
    title: String,
    on window: NSWindow? = NSApp.keyWindow
) {
    let hostView = NSHostingView(rootView: view)
    let vc = NSViewController()
    vc.view = hostView

    let win = NSWindow(contentViewController: vc)
    win.title = title
    win.styleMask = [.titled, .closable, .resizable]
    win.isReleasedWhenClosed = false

    if let parent = window {
        parent.beginSheet(win) { _ in }
    } else {
        win.makeKeyAndOrderFront(nil)
    }
}

/// 简单单行文本输入弹窗（NSAlert + accessoryView）
func presentTextInputDialog(
    title: String,
    message: String,
    placeholder: String = "",
    defaultText: String = "",
    on window: NSWindow? = NSApp.keyWindow,
    completion: @escaping (String?) -> Void
) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    textField.placeholderString = placeholder
    textField.stringValue = defaultText
    textField.bezelStyle = .roundedBezel
    alert.accessoryView = textField

    if let parent = window {
        alert.beginSheetModal(for: parent) { resp in
            completion(resp == .alertFirstButtonReturn ? textField.stringValue : nil)
        }
    } else {
        let resp = alert.runModal()
        completion(resp == .alertFirstButtonReturn ? textField.stringValue : nil)
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    @ObservedObject private var store = SSHStore.shared
    let collapsed: Bool
    /// 与终端保持一致的有效背景色（已包含 background-opacity alpha；glass 风格为 clear）
    let backgroundColor: NSColor
    /// 是否启用背景模糊（background-blur 非 false）
    let useBlur: Bool

    var onToggleCollapse: (() -> Void)?
    var onNewLocalTerminal: (() -> Void)?
    var onNewPortForward: (() -> Void)?
    var onOpenSSH: ((SSHConnection) -> Void)?
    var onAddSSH: ((SSHConnection) -> Void)?
    var onAddGroup: ((SSHGroup) -> Void)?

    // 编辑弹窗状态（SwiftUI sheet 已移除，改用 AppKit 弹窗）
    @State private var editingConnection: SSHConnection?
    @State private var editingGroup: SSHGroup?

    var body: some View {
        ZStack {
            // 先绘制模糊层，再绘制带透明度的背景色，最后叠内容
            if useBlur {
                VisualEffectView(
                    material: .underWindowBackground,
                    blendingMode: .behindWindow
                )
            }
            Color(nsColor: backgroundColor)

            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
    }

    // MARK: - 折叠模式

    private var collapsedBody: some View {
        VStack(spacing: 0) {
            Button(action: { onToggleCollapse?() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Expand Sidebar")
            Spacer()
            Button(action: {}) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .padding(.bottom, 8)
        }
        .frame(width: 32)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 展开模式

    private var expandedBody: some View {
        VStack(spacing: 0) {
            topToolbar
            searchBar.padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            connectionList
            Divider()
            settingsButton
        }
        .frame(minWidth: 150)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 顶部工具栏

    private var topToolbar: some View {
        HStack(spacing: 0) {
            Button(action: { onToggleCollapse?() }) {
                Image(systemName: collapsed ? "sidebar.right" : "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand Sidebar" : "Collapse Sidebar")
            .padding(.leading, 4)

            if !collapsed {
                Spacer()
                HStack(spacing: 2) {
                    Button(action: { showAddSSHDialog() }) {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).help("New SSH Connection")

                    Button(action: { showAddGroupDialog() }) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).help("New Group")

                    Button(action: { onNewLocalTerminal?() }) {
                        Image(systemName: "plus.square").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).help("New Local Terminal")

                    Button(action: { onNewPortForward?() }) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).help("New Port Forward")
                }
                .padding(.trailing, 4)
            }
        }
        .frame(height: 32)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
            TextField("Search...", text: $store.searchText).textFieldStyle(.plain).font(.system(size: 12))
            if !store.searchText.isEmpty {
                Button(action: { store.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    // MARK: - 设置按钮

    private var settingsButton: some View {
        Button(action: {}) {
            HStack(spacing: 4) {
                Image(systemName: "gearshape").font(.system(size: 11))
                Text("Settings").font(.system(size: 11))
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    // MARK: - 连接列表

    private var connectionList: some View {
        List {
            let defaultConns = filtered(store.ungroupedConnections)
            let defaultCount = store.ungroupedConnections.count
            Section("默认 (\(defaultCount))") {
                if defaultConns.isEmpty {
                    Text("No connections").font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(defaultConns) { conn in
                    connectionRow(conn)
                }
            }

            ForEach(store.groups) { group in
                let conns = filtered(store.connections(for: group.id))
                let totalCount = store.connections(for: group.id).count
                Section {
                    if conns.isEmpty {
                        Text("No connections").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    ForEach(conns) { conn in
                        connectionRow(conn)
                    }
                } header: {
                    GroupHeaderView(
                        name: group.name, count: totalCount,
                        onRename: {
                            editingGroup = group
                            showRenameGroupDialog()
                        },
                        onDelete: {
                            store.removeGroup(group.id)
                        }
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 连接行

    private func connectionRow(_ conn: SSHConnection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack").font(.system(size: 10)).foregroundColor(.accentColor).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(conn.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(conn.host):\(conn.port)").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenSSH?(conn) }
        .contextMenu {
            Button("Edit") {
                editingConnection = conn
                showEditSSHDialog()
            }
            Button("Delete", role: .destructive) { store.removeConnection(conn.id) }
        }
    }

    private func filtered(_ list: [SSHConnection]) -> [SSHConnection] {
        store.searchText.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(store.searchText) }
    }

    // MARK: - 弹窗

    private func showAddGroupDialog() {
        let alert = NSAlert()
        alert.messageText = "New Group"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        tf.placeholderString = "Group Name"
        tf.bezelStyle = .roundedBezel
        alert.accessoryView = tf

        if let win = NSApp.keyWindow {
            alert.beginSheetModal(for: win) { resp in
                if resp == .alertFirstButtonReturn, !tf.stringValue.isEmpty {
                    let group = SSHGroup(name: tf.stringValue)
                    store.addGroup(group)
                    onAddGroup?(group)
                }
            }
        }
    }

    private func showRenameGroupDialog() {
        guard let group = editingGroup else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Rename Group"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            tf.stringValue = group.name
            tf.bezelStyle = .roundedBezel
            alert.accessoryView = tf

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn, !tf.stringValue.isEmpty {
                        var updated = group
                        updated.name = tf.stringValue
                        self.store.updateGroup(updated)
                    }
                }
            }
        }
    }

    private func showEditSSHDialog() {
        let conn = editingConnection
        DispatchQueue.main.async {
            guard let conn else { return }
            guard let parent = NSApp.keyWindow else { return }

            let sheet = NSWindow(contentViewController: NSViewController())
            sheet.title = "编辑主机"
            sheet.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            sheet.titlebarAppearsTransparent = true
            sheet.titleVisibility = .hidden
            sheet.standardWindowButton(.closeButton)?.isHidden = true
            sheet.standardWindowButton(.miniaturizeButton)?.isHidden = true
            sheet.standardWindowButton(.zoomButton)?.isHidden = true
            sheet.isMovableByWindowBackground = true
            sheet.setContentSize(NSSize(width: 520, height: 620))
            sheet.isReleasedWhenClosed = false

            let view = EditSSHView(
                connection: conn,
                sshStore: SSHStore.shared,
                credentialStore: SSHCredentialStore.shared,
                onSave: { updated in
                    SSHStore.shared.updateConnection(updated)
                },
                onDismiss: { [weak parent, weak sheet] in
                    guard let parent, let sheet else { return }
                    parent.endSheet(sheet)
                }
            )
            sheet.contentViewController?.view = NSHostingView(rootView: view)
            parent.beginSheet(sheet) { _ in }
        }
    }

    private func showAddSSHDialog() {
        DispatchQueue.main.async {
            guard let parent = NSApp.keyWindow else { return }

            let sheet = NSWindow(contentViewController: NSViewController())
            sheet.title = "创建主机"
            sheet.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            sheet.titlebarAppearsTransparent = true
            sheet.titleVisibility = .hidden
            sheet.standardWindowButton(.closeButton)?.isHidden = true
            sheet.standardWindowButton(.miniaturizeButton)?.isHidden = true
            sheet.standardWindowButton(.zoomButton)?.isHidden = true
            sheet.isMovableByWindowBackground = true
            sheet.setContentSize(NSSize(width: 520, height: 620))
            sheet.isReleasedWhenClosed = false

            let view = AddSSHView(
                sshStore: SSHStore.shared,
                credentialStore: SSHCredentialStore.shared,
                onSave: { conn in
                    SSHStore.shared.addConnection(conn)
                },
                onDismiss: { [weak parent, weak sheet] in
                    guard let parent, let sheet else { return }
                    parent.endSheet(sheet)
                }
            )
            sheet.contentViewController?.view = NSHostingView(rootView: view)
            parent.beginSheet(sheet) { _ in }
        }
    }
}

// MARK: - GroupHeaderView

struct GroupHeaderView: View {
    let name: String
    let count: Int
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack {
            Text("\(name) (\(count))").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rename", action: { onRename?() })
            Button("Delete", role: .destructive, action: { onDelete?() })
        }
    }
}
