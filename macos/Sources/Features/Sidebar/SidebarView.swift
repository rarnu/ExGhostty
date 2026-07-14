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
    let backgroundOpacity: CGFloat
    let hasBlur: Bool

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
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .background(hasBlur ? Color.clear : Color(.windowBackgroundColor).opacity(max(0.1, backgroundOpacity)))
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
        .background(hasBlur ? Color.clear : Color(.windowBackgroundColor).opacity(max(0.1, backgroundOpacity)))
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
            let view = EditSSHView(connection: conn) { updated in
                SSHStore.shared.updateConnection(updated)
            }
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 320)

            let vc = NSViewController()
            vc.view = hostingView

            let win = NSWindow(contentViewController: vc)
            win.setContentSize(NSSize(width: 360, height: 320))
            win.title = "Edit SSH Connection"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false

            if let parent = NSApp.keyWindow {
                parent.beginSheet(win) { _ in }
            }
        }
    }

    private func showAddSSHDialog() {
        DispatchQueue.main.async {
            let view = AddSSHView(
                sshStore: SSHStore.shared,
                onAdd: { conn in
                    SSHStore.shared.addConnection(conn)
                }
            )
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 380)

            let vc = NSViewController()
            vc.view = hostingView

            let win = NSWindow(contentViewController: vc)
            win.setContentSize(NSSize(width: 360, height: 380))
            win.title = "New SSH Connection"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false

            if let parent = NSApp.keyWindow {
                parent.beginSheet(win) { _ in }
            }
        }
    }
}

// MARK: - AddSSHView

struct AddSSHView: View {
    let sshStore: SSHStore
    var onAdd: ((SSHConnection) -> Void)?

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authType: SSHAuthType = .password
    @State private var selectedGroupID: UUID? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("New SSH Connection").font(.headline)
            Group {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username (optional)", text: $username)
                Picker("Auth Type", selection: $authType) {
                    Text("Password").tag(SSHAuthType.password)
                    Text("Key").tag(SSHAuthType.key)
                    Text("Agent").tag(SSHAuthType.agent)
                }
                if !sshStore.groups.isEmpty {
                    Picker("Group", selection: $selectedGroupID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(sshStore.groups) { group in
                            Text(group.name).tag(group.id as UUID?)
                        }
                    }
                }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { if let w = NSApp.keyWindow { w.endSheet(w.attachedSheet ?? w) } }
                Button("Add") {
                    let conn = SSHConnection(
                        name: name, host: host, port: UInt16(port) ?? 22,
                        username: username, groupID: selectedGroupID, authType: authType)
                    onAdd?(conn)
                    if let w = NSApp.keyWindow { w.endSheet(w.attachedSheet ?? w) }
                }.buttonStyle(.borderedProminent).disabled(name.isEmpty || host.isEmpty)
            }
        }
        .padding(20).frame(width: 340)
    }
}

// MARK: - EditSSHView

struct EditSSHView: View {
    let connection: SSHConnection
    var onSave: ((SSHConnection) -> Void)?

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authType: SSHAuthType
    @State private var selectedGroupID: UUID?
    @State private var sshStore = SSHStore.shared

    init(connection: SSHConnection, onSave: ((SSHConnection) -> Void)? = nil) {
        self.connection = connection
        self.onSave = onSave
        _name = State(initialValue: connection.name)
        _host = State(initialValue: connection.host)
        _port = State(initialValue: String(connection.port))
        _username = State(initialValue: connection.username)
        _authType = State(initialValue: connection.authType)
        _selectedGroupID = State(initialValue: connection.groupID)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit SSH Connection").font(.headline)
            Group {
                TextField("Name", text: $name)
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username (optional)", text: $username)
                Picker("Auth Type", selection: $authType) {
                    Text("Password").tag(SSHAuthType.password)
                    Text("Key").tag(SSHAuthType.key)
                    Text("Agent").tag(SSHAuthType.agent)
                }
                if !sshStore.groups.isEmpty {
                    Picker("Group", selection: $selectedGroupID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(sshStore.groups) { group in
                            Text(group.name).tag(group.id as UUID?)
                        }
                    }
                }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { if let w = NSApp.keyWindow { w.endSheet(w.attachedSheet ?? w) } }
                Button("Save") {
                    var updated = connection
                    updated.name = name; updated.host = host
                    updated.port = UInt16(port) ?? 22; updated.username = username
                    updated.authType = authType; updated.groupID = selectedGroupID
                    onSave?(updated)
                    if let w = NSApp.keyWindow { w.endSheet(w.attachedSheet ?? w) }
                }.buttonStyle(.borderedProminent).disabled(name.isEmpty || host.isEmpty)
            }
        }
        .padding(20).frame(width: 340)
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
