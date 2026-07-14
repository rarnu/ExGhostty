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
    let sshStore: SSHStore
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
    @State private var isPasswordVisible = false
    @State private var showAdvanced = false

    @State private var isTesting = false
    @State private var testResult: TestResult?

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
        .onAppear {
            // 确保配置窗口能成为 keyWindow，从而让输入框获得标准复制粘贴快捷键
            NSApp.keyWindow?.makeKey()
        }
        .onChange(of: testSignature) { _ in
            testResult = nil
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
                items: [("密码登录", .password), ("密钥登录", .key)]
            )

            VStack(alignment: .leading, spacing: 6) {
                label("用户名（可选）")
                TextField("例如: root", text: $username)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
            }

            if authMode == .password {
                VStack(alignment: .leading, spacing: 6) {
                    label("密码（可选）")
                    HStack(spacing: 4) {
                        if isPasswordVisible {
                            TextField("使用此密码自动登录", text: $password)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField("使用此密码自动登录", text: $password)
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
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    label("密钥文件")
                    HStack(spacing: 8) {
                        Text(keyPath.isEmpty ? "未选择密钥文件" : keyPath)
                            .font(.system(size: 12))
                            .foregroundColor(keyPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)

                        Spacer()

                        Button("选择文件") {
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
                        Text("请选择本地 SSH 私钥文件（如 ~/.ssh/id_rsa）")
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
                    ("SSH 跳板", .jumpHost)
                ]
            )

            if connectionMethod == .jumpHost {
                jumpHostPicker
            }
        }
    }

    private var jumpHostPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("跳板主机")
            Picker("", selection: $jumpHostID) {
                Text("请选择跳板主机").tag(nil as UUID?)
                ForEach(availableJumpHosts) { conn in
                    Text("\(conn.name) (\(conn.host):\(conn.port))").tag(conn.id as UUID?)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)

            if availableJumpHosts.isEmpty {
                Text("暂无可用跳板主机，请先创建其他 SSH 连接")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var availableJumpHosts: [SSHConnection] {
        sshStore.connections.filter { $0.id != mode.editingID }
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
            Button(isTesting ? "测试中..." : "测试连接") {
                testConnection()
            }
            .buttonStyle(.bordered)
            .disabled(!canTest)

            if case .success = testResult {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .help("连接测试通过")
            } else if case .failure = testResult {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .help("连接测试失败")
            }

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
        canTest &&
        testResult == .success
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

    private func selectKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.isAccessoryViewDisclosed = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                keyPath = url.path
            }
        }
    }

    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil

        let testConfig = SSHTestConfig(
            host: host,
            port: UInt16(port) ?? 22,
            username: username,
            authMode: authMode,
            password: password,
            keyPath: keyPath.isEmpty ? nil : keyPath,
            connectionMethod: connectionMethod,
            jumpHost: jumpHostConnection
        )

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = SSHTester.test(config: testConfig)
            DispatchQueue.main.async { [self] in
                isTesting = false
                switch result {
                case .success:
                    testResult = .success
                case .failure(let error):
                    let message = error.localizedDescription
                    testResult = .failure(message)
                    showTestError(message)
                }
            }
        }
    }

    private var jumpHostConnection: SSHConnection? {
        guard connectionMethod == .jumpHost, let jumpHostID else { return nil }
        return sshStore.connections.first(where: { $0.id == jumpHostID })
    }

    private func showTestError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "连接测试失败"
        alert.informativeText = message.isEmpty ? "无法连接到目标主机，请检查地址、端口、用户名及认证信息。" : message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func save() {
        let portNum = UInt16(port) ?? 22
        let finalKeyPath = authMode == .key ? (keyPath.isEmpty ? nil : keyPath) : nil
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
                keyPath: finalKeyPath,
                connectionMethod: connectionMethod,
                jumpHostID: connectionMethod == .jumpHost ? jumpHostID : nil,
                notes: notes
            )
        }
        onSave(conn)
        onDismiss()
    }
}

// MARK: - 测试连接模型

private enum TestResult: Equatable {
    case success
    case failure(String)
}

private struct SSHTestConfig {
    let host: String
    let port: UInt16
    let username: String
    let authMode: SSHAuthMode
    let password: String
    let keyPath: String?
    let connectionMethod: SSHConnectionMethod
    let jumpHost: SSHConnection?
}

private enum SSHTester {
    enum TestError: LocalizedError {
        case sshNotFound
        case sshpassNotFound
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .sshNotFound:
                return "未找到系统 ssh 命令"
            case .sshpassNotFound:
                return "未找到 sshpass，无法测试密码登录"
            case .connectionFailed(let msg):
                return msg
            }
        }
    }

    static func test(config: SSHTestConfig) -> Result<Void, Error> {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            return .failure(TestError.sshNotFound)
        }

        var args: [String] = [
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new"
        ]

        if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
            let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
            let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
            args += ["-J", "\(jumpUser)\(jump.host)\(jumpPort)"]
        }

        if config.authMode == .key, let keyPath = config.keyPath {
            args += ["-i", keyPath, "-o", "BatchMode=yes"]
        } else if config.authMode == .password, !config.password.isEmpty {
            // 密码登录优先使用 sshpass 进行真实测试；否则退而求其次检测主机端口可达性
            if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/sshpass") ||
               FileManager.default.isExecutableFile(atPath: "/usr/local/bin/sshpass") {
                return testWithSshpass(config: config)
            }
            return testHostReachability(config: config)
        } else {
            args += ["-o", "BatchMode=yes"]
        }

        let userPrefix = config.username.isEmpty ? "" : "\(config.username)@"
        args += ["\(userPrefix)\(config.host)"]

        if config.port != 22 {
            args += ["-p", String(config.port)]
        }

        args += ["exit"]

        return runSSH(args: args)
    }

    private static func testWithSshpass(config: SSHTestConfig) -> Result<Void, Error> {
        let sshpassPath: String
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/sshpass") {
            sshpassPath = "/opt/homebrew/bin/sshpass"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/sshpass") {
            sshpassPath = "/usr/local/bin/sshpass"
        } else {
            return .failure(TestError.sshpassNotFound)
        }

        var sshArgs = [
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new"
        ]

        if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
            let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
            let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
            sshArgs += ["-J", "\(jumpUser)\(jump.host)\(jumpPort)"]
        }

        let userPrefix = config.username.isEmpty ? "" : "\(config.username)@"
        sshArgs += ["\(userPrefix)\(config.host)"]

        if config.port != 22 {
            sshArgs += ["-p", String(config.port)]
        }

        sshArgs += ["exit"]

        let args = ["-p", config.password, "/usr/bin/ssh"] + sshArgs
        return runSSH(args: args, executable: sshpassPath)
    }

    private static func runSSH(args: [String], executable: String = "/usr/bin/ssh") -> Result<Void, Error> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.terminationStatus == 0 {
                return .success(())
            } else {
                let message = output.isEmpty ? "SSH 进程退出码 \(task.terminationStatus)" : output
                return .failure(TestError.connectionFailed(message))
            }
        } catch {
            return .failure(error)
        }
    }

    private static func testHostReachability(config: SSHTestConfig) -> Result<Void, Error> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        task.arguments = ["-z", "-G", "10", "-w", "10", config.host, String(config.port)]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                return .success(())
            } else {
                return .failure(TestError.connectionFailed("无法连接到 \(config.host):\(config.port)，请检查地址和端口是否可达"))
            }
        } catch {
            return .failure(error)
        }
    }
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
