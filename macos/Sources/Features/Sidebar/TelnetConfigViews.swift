import SwiftUI
import AppKit

// MARK: - Telnet 配置表单（新增/编辑共用）

struct TelnetConfigFormView: View {
    enum Mode {
        case add
        case edit(SSHConnection)

        var isAdd: Bool {
            if case .add = self { return true }
            return false
        }

        var editingID: UUID? {
            if case .edit(let conn) = self { return conn.id }
            return nil
        }
    }

    let mode: Mode
    @ObservedObject var sshStore: SSHStore
    let onSave: (SSHConnection) -> Void
    let onDismiss: () -> Void

    // MARK: - State

    @State private var name = ""
    @State private var host = ""
    @State private var port = "23"
    @State private var username = ""
    @State private var password = ""
    @State private var groupID: UUID?
    @State private var notes = ""
    @State private var isPasswordVisible = false

    // MARK: - Init

    init(
        mode: Mode,
        sshStore: SSHStore = .shared,
        onSave: @escaping (SSHConnection) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.sshStore = sshStore
        self.onSave = onSave
        self.onDismiss = onDismiss

        if case .edit(let conn) = mode {
            _name = State(initialValue: conn.name)
            _host = State(initialValue: conn.host)
            _port = State(initialValue: String(conn.port))
            _username = State(initialValue: conn.username)
            _password = State(initialValue: conn.password)
            _groupID = State(initialValue: conn.groupID)
            _notes = State(initialValue: conn.notes)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameSection
                    groupSection
                    hostSection
                    authSection
                    notesSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .padding(.top, 12)

            Divider()

            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            NSApp.keyWindow?.makeKey()
        }
    }

    // MARK: - 名称

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            requiredLabel("Name".localized)

            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)

                TextField("e.g. H3".localized, text: $name)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - 分组

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Group".localized)
            Picker("", selection: $groupID) {
                Text("Ungrouped".localized).tag(Optional<UUID>.none)
                ForEach(sshStore.groups) { group in
                    Text(group.name).tag(Optional(group.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    // MARK: - 地址 / 端口

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            requiredLabel("Address".localized)

            HStack(spacing: 12) {
                TextField("e.g. 192.168.1.10 or server.com".localized, text: $host)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)

                TextField("23", text: $port)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
                    .frame(width: 80)
                    .onChange(of: port) { newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue {
                            port = filtered
                        }
                    }
            }

            Text("Fill in the Telnet service address and port.".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 用户 / 密码

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("User".localized)

            HStack(spacing: 12) {
                TextField("Username (optional)".localized, text: $username)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)

                HStack(spacing: 4) {
                    if isPasswordVisible {
                        TextField("Password (optional)".localized, text: $password)
                            .textFieldStyle(.plain)
                    } else {
                        SecureField("Password (optional)".localized, text: $password)
                            .textFieldStyle(.plain)
                    }

                    Button(action: { isPasswordVisible.toggle() }) {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            }

            Text("Fill in the username and password when the device requires login.".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 备注

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Notes".localized)
            TextEditor(text: $notes)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
                .frame(height: 58)
        }
    }

    // MARK: - 底部工具栏

    private var bottomBar: some View {
        HStack {
            Spacer()

            Button("Cancel".localized) {
                onDismiss()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button("OK".localized) {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !name.isEmpty && !host.isEmpty
    }

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

    // MARK: - Actions

    private func save() {
        let portNum = UInt16(port) ?? 23
        let conn: SSHConnection
        switch mode {
        case .add:
            conn = SSHConnection(
                name: name,
                host: host,
                port: portNum,
                username: username,
                groupID: groupID,
                type: .telnet,
                authMode: .password,
                password: password,
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
                type: .telnet,
                authMode: .password,
                password: password,
                notes: notes
            )
        }
        onSave(conn)
        onDismiss()
    }
}
