import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar View

/// Ghostty 左侧栏主视图
struct SidebarView: View {
    @ObservedObject private var store = SSHStore.shared

    /// 侧边栏是否折叠（仅读，由父容器控制）
    let collapsed: Bool

    /// 来自配置的 background-opacity
    let backgroundOpacity: CGFloat

    /// 是否有磨砂玻璃效果
    let hasBlur: Bool

    /// 回调闭包
    var onToggleCollapse: (() -> Void)?
    var onNewLocalTerminal: (() -> Void)?
    var onNewPortForward: (() -> Void)?
    var onOpenSSH: ((SSHConnection) -> Void)?
    var onAddSSH: ((SSHConnection) -> Void)?
    var onAddGroup: ((SSHGroup) -> Void)?

    // 编辑弹窗状态
    @State private var showAddSSH = false
    @State private var showAddGroup = false
    @State private var editingConnection: SSHConnection?
    @State private var showEditSSH = false

    var body: some View {
        if collapsed {
            // 折叠模式：紧凑图标栏
            VStack(spacing: 0) {
                // 展开按钮（顶部）
                Button(action: { onToggleCollapse?() }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("Expand Sidebar")

                Spacer()

                // 设置按钮（底部）
                Button(action: {
                    // TODO: 设置功能暂未实现
                }) {
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
            .background(hasBlur ? Color.clear : Color(.windowBackgroundColor).opacity(max(0.1, backgroundOpacity)))
        } else {
            // 展开模式：完整侧边栏
            expandedBody
        }
    }

    /// 展开模式下的完整侧边栏
    private var expandedBody: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            topToolbar

            // 搜索框
            searchBar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            Divider()

            // 连接列表
            connectionList

            // 底部设置按钮
            Divider()
            Button(action: {
                // TODO: 设置功能暂未实现
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text("Settings")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .frame(minWidth: 150)
        .frame(maxWidth: .infinity)
        .background(hasBlur ? Color.clear : Color(.windowBackgroundColor).opacity(max(0.1, backgroundOpacity)))
        .sheet(isPresented: $showAddSSH) {
            AddSSHView(onAdd: { conn in
                store.addConnection(conn)
                onAddSSH?(conn)
            })
        }
        .sheet(isPresented: $showAddGroup) {
            AddGroupView(onAdd: { group in
                store.addGroup(group)
                onAddGroup?(group)
            })
        }
        .sheet(isPresented: $showEditSSH) {
            if let conn = editingConnection {
                EditSSHView(connection: conn) { updated in
                    store.updateConnection(updated)
                }
            }
        }
    }

    // MARK: - 顶部工具栏

    private var topToolbar: some View {
        HStack(spacing: 0) {
            // 折叠/展开按钮
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

                // 四个操作按钮
                HStack(spacing: 2) {
                    // 1. 新增 SSH
                    Button(action: { showAddSSH = true }) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("New SSH Connection")

                    // 2. 新增分组
                    Button(action: { showAddGroup = true }) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("New Group")

                    // 3. 新建本地 Terminal
                    Button(action: { onNewLocalTerminal?() }) {
                        Image(systemName: "plus.square")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("New Local Terminal")

                    // 4. 新建端口转发
                    Button(action: { onNewPortForward?() }) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("New Port Forward")
                }
                .padding(.trailing, 4)
            }
        }
        .frame(height: 32)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            TextField("Search...", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !store.searchText.isEmpty {
                Button(action: { store.searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    // MARK: - 连接列表

    private var connectionList: some View {
        List {
            if !store.groups.isEmpty {
                if !store.ungroupedConnections.isEmpty {
                    let ungrouped = filtered(store.ungroupedConnections)
                    if !ungrouped.isEmpty {
                        Section("Ungrouped") {
                            ForEach(ungrouped) { conn in
                                connectionRow(conn)
                            }
                        }
                    }
                }

                ForEach(store.groups) { group in
                    let conns = filtered(store.connections(for: group.id))
                    if !conns.isEmpty {
                        Section(group.name) {
                            ForEach(conns) { conn in
                                connectionRow(conn)
                            }
                        }
                    }
                }
            } else {
                ForEach(filtered(store.connections)) { conn in
                    connectionRow(conn)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 连接行

    private func connectionRow(_ conn: SSHConnection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(conn.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(conn.host):\(conn.port)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "ellipsis")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpenSSH?(conn)
        }
        .contextMenu {
            Button("Edit") {
                editingConnection = conn
                showEditSSH = true
            }
            Button("Delete", role: .destructive) {
                store.removeConnection(conn.id)
            }
        }
    }

    private func filtered(_ list: [SSHConnection]) -> [SSHConnection] {
        if store.searchText.isEmpty { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(store.searchText) }
    }
}

// MARK: - 添加/编辑 SSH 弹窗

struct AddSSHView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authType: SSHAuthType = .password

    var onAdd: ((SSHConnection) -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text("New SSH Connection")
                .font(.headline)

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
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let p = UInt16(port) ?? 22
                    let conn = SSHConnection(
                        name: name,
                        host: host,
                        port: p,
                        username: username,
                        authType: authType
                    )
                    onAdd?(conn)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || host.isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

struct EditSSHView: View {
    @Environment(\.dismiss) private var dismiss

    let connection: SSHConnection
    var onSave: ((SSHConnection) -> Void)?

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authType: SSHAuthType

    init(connection: SSHConnection, onSave: ((SSHConnection) -> Void)? = nil) {
        self.connection = connection
        self.onSave = onSave
        _name = State(initialValue: connection.name)
        _host = State(initialValue: connection.host)
        _port = State(initialValue: String(connection.port))
        _username = State(initialValue: connection.username)
        _authType = State(initialValue: connection.authType)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit SSH Connection")
                .font(.headline)

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
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var updated = connection
                    updated.name = name
                    updated.host = host
                    updated.port = UInt16(port) ?? 22
                    updated.username = username
                    updated.authType = authType
                    onSave?(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || host.isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

struct AddGroupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    var onAdd: ((SSHGroup) -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Group")
                .font(.headline)

            TextField("Group Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onAdd?(SSHGroup(name: name))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
