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
    @State private var port = "22"
    @State private var username = ""
    @State private var authMode: SSHAuthMode = .password
    @State private var password = ""
    @State private var keyPath = ""
    @State private var connectionMethod: SSHConnectionMethod = .direct
    @State private var jumpHostID: UUID?
    @State private var groupID: UUID?
    @State private var notes = ""
    @State private var timeoutMs = "30000"
    @State private var heartbeatMs = "30000"
    @State private var encoding: String = SSHTerminalEncoding.utf8.rawValue
    @State private var x11Forwarding = false
    @State private var isPasswordVisible = false
    @State private var showAdvanced = false

    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var availableJumpHosts: [SSHConnection] = []

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
            _authMode = State(initialValue: conn.authMode)
            _password = State(initialValue: conn.password)
            _keyPath = State(initialValue: conn.keyPath ?? "")
            _connectionMethod = State(initialValue: conn.connectionMethod)
            _jumpHostID = State(initialValue: conn.jumpHostID)
            _groupID = State(initialValue: conn.groupID)
            _notes = State(initialValue: conn.notes)
            _timeoutMs = State(initialValue: String(conn.timeoutMs))
            _heartbeatMs = State(initialValue: String(conn.heartbeatMs))
            _encoding = State(initialValue: conn.encoding)
            _x11Forwarding = State(initialValue: conn.x11Forwarding)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(.top, 12)

            Divider()

            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            // 确保配置窗口能成为 keyWindow，从而让输入框获得标准复制粘贴快捷键
            NSApp.keyWindow?.makeKey()
            refreshAvailableJumpHosts()
        }
        .onReceive(sshStore.objectWillChange) {
            // objectWillChange 在 @Published 属性实际变更前触发，
            // 因此延后到下一个 runloop 再刷新，确保读到最新数据。
            DispatchQueue.main.async {
                refreshAvailableJumpHosts()
            }
        }
        .onChange(of: testSignature) { _ in
            testResult = nil
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

                TextField("e.g. Production Web 01".localized, text: $name)
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
                requiredLabel("IP Address".localized)
                TextField("e.g. 192.168.1.10 or server.com".localized, text: $host)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Port".localized)
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
            label("Authentication".localized)

            Picker("", selection: $authMode) {
                Text("Password".localized).tag(SSHAuthMode.password)
                Text("Key".localized).tag(SSHAuthMode.key)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                label("Username (optional)".localized)
                TextField("e.g. root".localized, text: $username)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
            }

            if authMode == .password {
                VStack(alignment: .leading, spacing: 6) {
                    label("Password (optional)".localized)
                    HStack(spacing: 4) {
                        if isPasswordVisible {
                            TextField("Use this password to log in automatically".localized, text: $password)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField("Use this password to log in automatically".localized, text: $password)
                                .textFieldStyle(.plain)
                        }

                        Button(action: { isPasswordVisible.toggle() }) {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isPasswordVisible ? "Hide Password".localized : "Show Password".localized)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    label("Key File".localized)
                    HStack(spacing: 8) {
                        Text(keyPath.isEmpty ? "No key file selected".localized : keyPath)
                            .font(.system(size: 12))
                            .foregroundColor(keyPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)

                        Spacer()

                        Button("Choose File".localized) {
                            selectKeyFile()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)

                    if keyPath.isEmpty {
                        Text("Please select a local SSH private key file (e.g. ~/.ssh/id_rsa)".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
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

    // MARK: - 连接方式

    private var connectionMethodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Connection Method".localized)
            Picker("", selection: $connectionMethod) {
                Text("Direct".localized).tag(SSHConnectionMethod.direct)
                Text("SSH Jump Host".localized).tag(SSHConnectionMethod.jumpHost)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if connectionMethod == .jumpHost {
                jumpHostPicker
            }
        }
    }

    private var jumpHostPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Jump Host".localized)
            Picker("", selection: $jumpHostID) {
                Text("Please select a jump host".localized).tag(Optional<UUID>.none)
                ForEach(availableJumpHosts) { conn in
                    Text("\(conn.name) (\(conn.host):\(conn.port))").tag(Optional(conn.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(availableJumpHosts.isEmpty)
            // 强制 Picker 随可用跳板机列表重建，避免 SwiftUI 缓存已删除的选项
            .id(jumpHostMenuID)

            if availableJumpHosts.isEmpty {
                Text("No jump hosts available. Create another SSH connection first.".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var jumpHostMenuID: String {
        availableJumpHosts.map(\.id.uuidString).sorted().joined(separator: "-")
    }

    private func refreshAvailableJumpHosts() {
        availableJumpHosts = sshStore.connections.filter { candidate in
            guard candidate.id != mode.editingID else { return false }
            return !wouldCreateCycle(candidate)
        }
    }

    /// 检测将 candidate 设为跳板机后是否会形成回环（即 candidate 的跳板链最终指向当前编辑的连接）
    private func wouldCreateCycle(_ candidate: SSHConnection) -> Bool {
        guard let editingID = mode.editingID else { return false }
        var visited: Set<UUID> = []
        var current: SSHConnection? = candidate
        while let conn = current {
            guard !visited.contains(conn.id) else { return true }
            visited.insert(conn.id)
            if conn.id == editingID { return true }
            guard conn.connectionMethod == .jumpHost,
                  let nextID = conn.jumpHostID else { break }
            current = sshStore.connections.first(where: { $0.id == nextID })
        }
        return false
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

    // MARK: - 高级设置

    private var advancedSection: some View {
        DisclosureGroup(
            isExpanded: $showAdvanced,
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        numberField("Timeout (ms)".localized, value: $timeoutMs)
                        numberField("Heartbeat (ms)".localized, value: $heartbeatMs)
                    }

                    encodingPicker

                    Toggle("Enable X11 Forwarding".localized, isOn: $x11Forwarding)
                        .font(.system(size: 12))

                    if x11Forwarding && !SSHX11Environment.isAvailable {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 12))
                            Text("No local X server detected. On macOS, install and start XQuartz or X11 forwarding will not work.".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }

                    if heartbeatMs != "0" && (Int(heartbeatMs) ?? 0) > 0 {
                        Text(L("Heartbeat will use SSH ServerAliveInterval, sending a keepalive every %d seconds.", max(1, (Int(heartbeatMs) ?? 0) / 1000)))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            },
            label: {
                HStack {
                    Text("Advanced".localized)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation {
                        showAdvanced.toggle()
                    }
                }
            }
        )
    }

    private var encodingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Terminal Encoding".localized)
            Picker("", selection: $encoding) {
                ForEach(SSHTerminalEncoding.allCases, id: \.self) { enc in
                    Text(enc.displayName).tag(enc.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func numberField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField("0", text: value)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
                .onChange(of: value.wrappedValue) { newValue in
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered != newValue {
                        value.wrappedValue = filtered
                    }
                }
        }
    }

    // MARK: - 底部工具栏

    private var bottomBar: some View {
        HStack {
            Button(isTesting ? "Testing...".localized : "Test Connection".localized) {
                testConnection()
            }
            .buttonStyle(.bordered)
            .disabled(!canTest)

            if case .success = testResult {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .help("Connection test passed".localized)
            } else if case .failure = testResult {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .help("Connection test failed".localized)
            }

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

    private var canTest: Bool {
        !name.isEmpty &&
        !host.isEmpty &&
        !isTesting &&
        (connectionMethod != .jumpHost || availableJumpHosts.contains(where: { $0.id == jumpHostID }))
    }

    private var canSave: Bool {
        // 只需必填项填写完整即可保存，不再要求通过 Test Connection。
        !name.isEmpty &&
        !host.isEmpty &&
        (connectionMethod != .jumpHost || availableJumpHosts.contains(where: { $0.id == jumpHostID }))
    }

    private var testSignature: String {
        "\(name)\(host)\(port)\(username)\(authMode.rawValue)\(password)\(keyPath)\(connectionMethod.rawValue)\(jumpHostID?.uuidString ?? "")"
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

    private func selectKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.isAccessoryViewDisclosed = true

        // 用嵌套模态事件循环而不是 sheet：配置窗口本身处于 NSApp.runModal 会话中，
        // beginSheetModal 在该会话里第二次调用会静默失败（第一次能弹出，之后无反应）。
        // runModal 作为应用级模态面板会置顶显示，不会被配置窗口挡住，且可重复打开。
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            keyPath = url.path
        }
    }

    private func testConnection() {
        guard !isTesting else { return }
        guard let parent = NSApp.keyWindow else { return }

        let testConfig = SSHTestConfig(
            host: host,
            port: UInt16(port) ?? 22,
            username: username,
            authMode: authMode,
            password: password,
            keyPath: keyPath.isEmpty ? nil : keyPath,
            connectionMethod: connectionMethod,
            jumpHost: jumpHostConnection,
            timeoutMs: UInt32(timeoutMs) ?? 30000,
            heartbeatMs: UInt32(heartbeatMs) ?? 0,
            encoding: encoding,
            x11Forwarding: x11Forwarding
        )

        let detailView = SSHTestDetailView(config: testConfig) { success in
            self.isTesting = false
            self.testResult = success ? .success : .failure("")
        }

        let hostView = NSHostingView(rootView: detailView)
        let vc = NSViewController()
        vc.view = hostView

        let sheet = NSWindow(contentViewController: vc)
        sheet.title = "Connection Test Details".localized
        sheet.styleMask = [.titled, .closable]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.standardWindowButton(.miniaturizeButton)?.isHidden = true
        sheet.standardWindowButton(.zoomButton)?.isHidden = true
        sheet.isMovableByWindowBackground = true
        sheet.setContentSize(NSSize(width: 680, height: 420))
        sheet.isReleasedWhenClosed = false

        NSLog("[SSHConfigViews] beginSheet for test connection")
        parent.beginSheet(sheet) { _ in }
    }

    private var jumpHostConnection: SSHConnection? {
        guard connectionMethod == .jumpHost, let jumpHostID else { return nil }
        return sshStore.connections.first(where: { $0.id == jumpHostID })
    }

    private func save() {
        let portNum = UInt16(port) ?? 22
        let finalKeyPath = authMode == .key ? (keyPath.isEmpty ? nil : keyPath) : nil
        let timeout = UInt32(timeoutMs) ?? 30000
        let heartbeat = UInt32(heartbeatMs) ?? 0
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
                keyPath: finalKeyPath,
                connectionMethod: connectionMethod,
                jumpHostID: connectionMethod == .jumpHost ? jumpHostID : nil,
                notes: notes,
                timeoutMs: timeout,
                heartbeatMs: heartbeat,
                encoding: encoding,
                x11Forwarding: x11Forwarding
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
                keyPath: finalKeyPath,
                connectionMethod: connectionMethod,
                jumpHostID: connectionMethod == .jumpHost ? jumpHostID : nil,
                notes: notes,
                timeoutMs: timeout,
                heartbeatMs: heartbeat,
                encoding: encoding,
                x11Forwarding: x11Forwarding
            )
        }
        onSave(conn)
        onDismiss()
    }
}

// MARK: - 测试连接结果（用于表单图标状态）

private enum TestResult: Equatable {
    case success
    case failure(String)
}

// MARK: - 新增/编辑包装视图

struct AddSSHView: View {
    let sshStore: SSHStore
    let onSave: (SSHConnection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        SSHConfigFormView(
            mode: .add,
            sshStore: sshStore,
            onSave: onSave,
            onDismiss: onDismiss
        )
    }
}

struct EditSSHView: View {
    let connection: SSHConnection
    let sshStore: SSHStore
    let onSave: (SSHConnection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        SSHConfigFormView(
            mode: .edit(connection),
            sshStore: sshStore,
            onSave: onSave,
            onDismiss: onDismiss
        )
    }
}
