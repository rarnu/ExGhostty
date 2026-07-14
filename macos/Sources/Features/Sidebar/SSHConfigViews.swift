import SwiftUI
import AppKit

// MARK: - SSH 配置表单（新增/编辑共用）

struct SSHConfigFormView: View {
    enum Mode {
        case add
        case edit(SSHConnection)

        var isAdd: Bool {
            if case .add = self { return true }
            return false
        }
    }

    let mode: Mode
    let sshStore: SSHStore
    let credentialStore: SSHCredentialStore
    let onSave: (SSHConnection) -> Void
    let onDismiss: () -> Void

    // MARK: - State

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMode: SSHAuthMode = .manual
    @State private var password = ""
    @State private var credentialID: UUID?
    @State private var connectionMethod: SSHConnectionMethod = .direct
    @State private var groupID: UUID?
    @State private var notes = ""
    @State private var isPasswordVisible = false
    @State private var showAdvanced = false
    @State private var showCredentialManager = false

    // MARK: - Init

    init(
        mode: Mode,
        sshStore: SSHStore = .shared,
        credentialStore: SSHCredentialStore = .shared,
        onSave: @escaping (SSHConnection) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.sshStore = sshStore
        self.credentialStore = credentialStore
        self.onSave = onSave
        self.onDismiss = onDismiss

        if case .edit(let conn) = mode {
            _name = State(initialValue: conn.name)
            _host = State(initialValue: conn.host)
            _port = State(initialValue: String(conn.port))
            _username = State(initialValue: conn.username)
            _authMode = State(initialValue: conn.authMode)
            _password = State(initialValue: conn.password)
            _credentialID = State(initialValue: conn.credentialID)
            _connectionMethod = State(initialValue: conn.connectionMethod)
            _groupID = State(initialValue: conn.groupID)
            _notes = State(initialValue: conn.notes)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameSection
                    hostSection
                    authSection
                    groupSection
                    connectionMethodSection
                    notesSection
                    advancedSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Divider()

            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .sheet(isPresented: $showCredentialManager) {
            CredentialManagerView(credentialStore: credentialStore)
                .frame(width: 400, height: 300)
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            Text(mode.isAdd ? "创建主机" : "编辑主机")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    // MARK: - 名称

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            requiredLabel("名称")

            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)

                TextField("例如: Production Web 01", text: $name)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - IP / 端口

    private var hostSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                requiredLabel("IP 地址")
                TextField("例如: 192.168.1.10 或 server.com", text: $host)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("端口")
                TextField("22", text: $port)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
                    .frame(width: 80)
            }
        }
    }

    // MARK: - 认证方式

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("认证方式")

            segmentedPicker(
                selection: $authMode,
                items: [("手动输入", .manual), ("使用凭证", .credential)]
            )

            if authMode == .manual {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        label("用户名（可选）")
                        TextField("例如: root", text: $username)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(8)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        label("密码（可选）")
                        HStack(spacing: 4) {
                            if isPasswordVisible {
                                TextField("未选择凭证时可使用此密码自动登录", text: $password)
                                    .textFieldStyle(.plain)
                            } else {
                                SecureField("未选择凭证时可使用此密码自动登录", text: $password)
                                    .textFieldStyle(.plain)
                            }

                            Button(action: { isPasswordVisible.toggle() }) {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(isPasswordVisible ? "隐藏密码" : "显示密码")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("选择凭证", selection: $credentialID) {
                            Text("请选择凭证").tag(nil as UUID?)
                            ForEach(credentialStore.credentials) { cred in
                                Text(cred.name).tag(cred.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("管理凭证") {
                            showCredentialManager = true
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }

                    if credentialStore.credentials.isEmpty {
                        Text("暂无保存的凭证，点击“管理凭证”添加")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - 分组

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("分组")
            Picker("", selection: $groupID) {
                Text("未分组").tag(nil as UUID?)
                ForEach(sshStore.groups) { group in
                    Text(group.name).tag(group.id as UUID?)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - 连接方式

    private var connectionMethodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("连接方式")
            segmentedPicker(
                selection: $connectionMethod,
                items: [
                    ("直接连接", .direct),
                    ("SSH 跳板", .jumpHost),
                    ("代理访问", .proxy)
                ]
            )
        }
    }

    // MARK: - 备注

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("备注")
            TextEditor(text: $notes)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
                .frame(minHeight: 80)
        }
    }

    // MARK: - 高级设置

    private var advancedSection: some View {
        DisclosureGroup(
            isExpanded: $showAdvanced,
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("高级设置内容预留")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            },
            label: {
                Text("高级设置")
                    .font(.system(size: 13, weight: .medium))
            }
        )
    }

    // MARK: - 底部工具栏

    private var bottomBar: some View {
        HStack {
            Button("测试连接") {
                testConnection()
            }
            .buttonStyle(.bordered)
            .disabled(name.isEmpty || host.isEmpty)

            Spacer()

            Button("取消") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button("确定") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.isEmpty || host.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
    }

    private func requiredLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
            Text("*")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.red)
        }
    }

    private func segmentedPicker<T: Hashable>(
        selection: Binding<T>,
        items: [(String, T)]
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.1) { title, value in
                Button(action: { selection.wrappedValue = value }) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selection.wrappedValue == value ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selection.wrappedValue == value
                                ? Color(.selectedControlColor).opacity(0.5)
                                : Color.clear
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Actions

    private func testConnection() {
        // 简单模拟：弹窗提示测试逻辑（后续可接入真实 SSH 测试）
        let alert = NSAlert()
        alert.messageText = "测试连接"
        alert.informativeText = "将尝试连接 \(host):\(port)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func save() {
        let portNum = UInt16(port) ?? 22
        let conn: SSHConnection
        switch mode {
        case .add:
            conn = SSHConnection(
                name: name,
                host: host,
                port: portNum,
                username: username,
                groupID: groupID,
                authMode: authMode,
                password: password,
                credentialID: credentialID,
                connectionMethod: connectionMethod,
                notes: notes
            )
        case .edit(let existing):
            conn = SSHConnection(
                id: existing.id,
                name: name,
                host: host,
                port: portNum,
                username: username,
                groupID: groupID,
                authMode: authMode,
                password: password,
                credentialID: credentialID,
                connectionMethod: connectionMethod,
                notes: notes
            )
        }
        onSave(conn)
        onDismiss()
    }
}

// MARK: - 凭证管理弹窗

struct CredentialManagerView: View {
    @ObservedObject var credentialStore: SSHCredentialStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("管理凭证")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            List {
                ForEach(credentialStore.credentials) { cred in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(cred.name).font(.system(size: 12, weight: .medium))
                            Text(cred.username).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("删除") {
                            credentialStore.remove(cred.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            VStack(spacing: 8) {
                TextField("凭证名称", text: $name)
                TextField("用户名", text: $username)
                SecureField("密码", text: $password)
                Button("添加凭证") {
                    let cred = SSHCredential(name: name, username: username, password: password)
                    credentialStore.add(cred)
                    name = ""
                    username = ""
                    password = ""
                }
                .disabled(name.isEmpty || username.isEmpty)
            }
            .padding()
        }
    }
}

// MARK: - 新增/编辑包装视图

struct AddSSHView: View {
    let sshStore: SSHStore
    let credentialStore: SSHCredentialStore
    let onSave: (SSHConnection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        SSHConfigFormView(
            mode: .add,
            sshStore: sshStore,
            credentialStore: credentialStore,
            onSave: onSave,
            onDismiss: onDismiss
        )
    }
}

struct EditSSHView: View {
    let connection: SSHConnection
    let sshStore: SSHStore
    let credentialStore: SSHCredentialStore
    let onSave: (SSHConnection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        SSHConfigFormView(
            mode: .edit(connection),
            sshStore: sshStore,
            credentialStore: credentialStore,
            onSave: onSave,
            onDismiss: onDismiss
        )
    }
}
