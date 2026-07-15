import SwiftUI
import UniformTypeIdentifiers

// MARK: - SidebarView

struct SidebarView: View {
    @ObservedObject private var store = SSHStore.shared
    let collapsed: Bool
    /// 与终端保持一致的背景色（已包含 background-opacity alpha）
    let backgroundColor: NSColor

    var onToggleCollapse: (() -> Void)?
    var onNewLocalTerminal: (() -> Void)?
    var onOpenSSH: ((SSHConnection) -> Void)?
    var onAddSSH: ((SSHConnection) -> Void)?
    var onAddGroup: ((SSHGroup) -> Void)?

    // 编辑弹窗状态（SwiftUI sheet 已移除，改用 AppKit 弹窗）
    @State private var editingConnection: SSHConnection?
    @State private var editingGroup: SSHGroup?

    var body: some View {
        ZStack {
            // 背景色由 SidebarBackgroundView 提供，避免透明 layer 在 resize 时产生白色竖线。
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
            .sidebarTooltip("展开侧边栏")

            Button(action: { onNewLocalTerminal?() }) {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .sidebarTooltip("新建本地终端")

            Spacer()
            Button(action: {}) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .frame(height: 32)
            .sidebarTooltip("设置")
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
            .sidebarTooltip(collapsed ? "展开侧边栏" : "收起侧边栏")
            .padding(.leading, 4)

            if !collapsed {
                Spacer()
                HStack(spacing: 2) {
                    Button(action: { showAddSSHDialog() }) {
                        Image(systemName: "plus.square").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("新建 SSH 连接")

                    Button(action: { showAddGroupDialog() }) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("新建分组")

                    Button(action: { onNewLocalTerminal?() }) {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("新建本地终端")
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
                }.buttonStyle(.plain).sidebarTooltip("清除搜索")
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
                Image(systemName: "gearshape").font(.system(size: 13))
                Text("Settings").font(.system(size: 13))
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .frame(height: 32)
        .fixedSize(horizontal: false, vertical: true)
        .sidebarTooltip("设置")
        .padding(.bottom, 8)
    }

    // MARK: - 连接列表

    private var connectionList: some View {
        List {
            let defaultConns = filtered(store.ungroupedConnections)
            let defaultCount = store.ungroupedConnections.count
            Section {
                if defaultConns.isEmpty {
                    Text("No connections").font(.system(size: 12)).foregroundColor(.secondary)
                }
                ForEach(defaultConns) { conn in
                    connectionRow(conn)
                }
            } header: {
                Text("默认 (\(defaultCount))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            ForEach(store.groups) { group in
                let conns = filtered(store.connections(for: group.id))
                let totalCount = store.connections(for: group.id).count
                Section {
                    if conns.isEmpty {
                        Text("No connections").font(.system(size: 12)).foregroundColor(.secondary)
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 连接行

    private func connectionRow(_ conn: SSHConnection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack").font(.system(size: 12)).foregroundColor(.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(conn.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text("\(conn.host):\(conn.port)").font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                if !conn.notes.isEmpty {
                    Text(conn.notes)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenSSH?(conn) }
        .contextMenu {
            Button("Edit") {
                editingConnection = conn
                showEditSSHDialog()
            }
            Button(role: .destructive) {
                showDeleteConnectionConfirmation(conn)
            } label: {
                Text("Delete")
                    .foregroundColor(.red)
            }
        }
    }

    private func filtered(_ list: [SSHConnection]) -> [SSHConnection] {
        store.searchText.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(store.searchText) }
    }

    // MARK: - 弹窗

    private func showDeleteConnectionConfirmation(_ conn: SSHConnection) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "删除连接"
            alert.informativeText = "确定要删除 \"\(conn.name)\" 吗？此操作无法撤销。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn {
                        store.removeConnection(conn.id)
                    }
                }
            } else {
                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    store.removeConnection(conn.id)
                }
            }
        }
    }

    private func showAddGroupDialog() {
        guard let parent = NSApp.keyWindow else { return }
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        let store = self.store
        let onAddGroup = self.onAddGroup
        let controller = GroupNameWindowController(
            title: "New Group",
            placeholder: "Group Name",
            config: config,
            parentWindow: parent
        ) { name in
            guard let name, !name.isEmpty else { return }
            let group = SSHGroup(name: name)
            store.addGroup(group)
            onAddGroup?(group)
        }
        controller.showModal()
    }

    private func showRenameGroupDialog() {
        guard let group = editingGroup else { return }
        guard let parent = NSApp.keyWindow else { return }
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        let store = self.store
        let controller = GroupNameWindowController(
            title: "Rename Group",
            placeholder: "Group Name",
            defaultText: group.name,
            config: config,
            parentWindow: parent
        ) { name in
            guard let name, !name.isEmpty else { return }
            var updated = group
            updated.name = name
            store.updateGroup(updated)
        }
        controller.showModal()
    }

    private func showEditSSHDialog() {
        let conn = editingConnection
        DispatchQueue.main.async {
            guard let conn else { return }
            guard let parent = NSApp.keyWindow else { return }
            let config = (NSApp.delegate as? AppDelegate)?.ghostty.config

            let controller = SSHConfigWindowController(
                mode: .edit(conn),
                sshStore: SSHStore.shared,
                config: config,
                parentWindow: parent,
                onSave: { updated in
                    SSHStore.shared.updateConnection(updated)
                }
            )
            controller.showModal()
        }
    }

    private func showAddSSHDialog() {
        DispatchQueue.main.async {
            guard let parent = NSApp.keyWindow else { return }
            let config = (NSApp.delegate as? AppDelegate)?.ghostty.config

            let controller = SSHConfigWindowController(
                mode: .add,
                sshStore: SSHStore.shared,
                config: config,
                parentWindow: parent,
                onSave: { conn in
                    SSHStore.shared.addConnection(conn)
                }
            )
            controller.showModal()
        }
    }
}

// MARK: - Tooltip 辅助

/// 通过 AppKit toolTip 实现可靠的悬停提示，覆盖在按钮上方但点击可穿透。
private struct TooltipOverlay: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = TooltipPassThroughView()
        view.toolTip = text
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

private class TooltipPassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension View {
    /// 显示 macOS 原生悬停提示，并保证底层按钮仍可点击。
    func sidebarTooltip(_ text: String) -> some View {
        self.overlay(
            TooltipOverlay(text: text)
        )
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
            Text("\(name) (\(count))").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Rename", action: { onRename?() })
            Button(role: .destructive, action: { onDelete?() }) {
                Text("Delete")
                    .foregroundColor(.red)
            }
        }
    }
}

// MARK: - 端口转发管理页

struct PortForwardListView: View {
    @ObservedObject private var store = PortForwardStore.shared
    @ObservedObject private var sshStore = SSHStore.shared
    @State private var searchText: String = ""
    @State private var editingRule: PortForwardRule? = nil

    private var filteredRules: [PortForwardRule] {
        if searchText.isEmpty { return store.rules }
        return store.rules.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.localListenHost + ":" + String($0.localListenPort)).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if store.rules.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("端口转发")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("按关键字搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
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

            Spacer()

            Button(action: { showAddSheet() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var listView: some View {
        List {
            ForEach(filteredRules) { rule in
                ruleRow(rule)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            Text("暂无端口转发规则")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func ruleRow(_ rule: PortForwardRule) -> some View {
        let connection = sshStore.connections.first(where: { $0.id == rule.sshConnectionID })
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.system(size: 14, weight: .medium))
                    statusBadge(rule.isRunning)
                }
                Text(rule.summaryText(using: connection))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: { handleToggle(rule: rule) }) {
                Image(systemName: rule.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(rule.isRunning ? .orange : .green)
                    .frame(minWidth: 44, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            if rule.isRunning {
                Button("停止") {
                    handleToggle(rule: rule)
                }
            }
            Button("编辑") {
                showEditSheet(rule: rule)
            }
            Button("查看日志") {
                openPortForwardLog(rule: rule)
            }
            Button("清空日志") {
                store.clearLog(for: rule.id)
            }
            Button(role: .destructive) {
                store.removeRule(rule.id)
            } label: {
                Text("删除")
                    .foregroundColor(.red)
            }
        }
    }

    private func handleToggle(rule: PortForwardRule) {
        if rule.isRunning {
            store.stopRule(rule.id)
            return
        }

        // 远程转发不涉及本机监听端口，无需检查占用。
        guard rule.type == .local || rule.type == .dynamic else {
            store.startRule(rule.id)
            return
        }

        guard let pid = pidListening(on: rule.localListenPort) else {
            store.startRule(rule.id)
            return
        }

        let process = processName(for: pid) ?? "未知进程"
        let alert = NSAlert()
        alert.messageText = "端口 \(rule.localListenPort) 已被占用"
        alert.informativeText = "进程: \(process) (PID \(pid))\n是否结束该进程并启动端口转发？"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let proceed = {
            if killProcess(pid: pid) {
                self.store.startRule(rule.id)
            } else {
                self.showKillFailedAlert(process: process, pid: pid)
            }
        }

        if let win = NSApp.keyWindow {
            alert.beginSheetModal(for: win) { resp in
                if resp == .alertFirstButtonReturn { proceed() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            proceed()
        }
    }

    private func showKillFailedAlert(process: String, pid: Int32) {
        let alert = NSAlert()
        alert.messageText = "无法结束进程"
        alert.informativeText = "结束 \(process) (PID \(pid)) 失败，端口转发未能启动。"
        alert.addButton(withTitle: "确定")
        if let win = NSApp.keyWindow {
            alert.beginSheetModal(for: win) { _ in }
        } else {
            alert.runModal()
        }
    }

    /// 查询占用指定 TCP 端口的监听进程 PID，使用 lsof -ti :<port>。
    private func pidListening(on port: UInt16) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let firstLine = text.components(separatedBy: .newlines).first,
                  let pid = Int32(firstLine) else {
                return nil
            }
            return pid
        } catch {
            return nil
        }
    }

    /// 根据 PID 获取进程名称。
    private func processName(for pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// 结束指定 PID 的进程。
    @discardableResult
    private func killProcess(pid: Int32) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-9", "\(pid)"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func openPortForwardLog(rule: PortForwardRule) {
        DispatchQueue.main.async {
            self.store.ensureLogFileExists(for: rule.id)
            let url = self.store.logURL(for: rule.id)
            NSWorkspace.shared.open(url)
        }
    }

    private func statusBadge(_ running: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(running ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(running ? "运行中" : "已停止")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func showAddSheet() {
        let newRule = PortForwardRule(name: "", type: .local)
        editingRule = newRule
        presentEditSheet(rule: newRule, isNew: true)
    }

    private func showEditSheet(rule: PortForwardRule) {
        editingRule = rule
        presentEditSheet(rule: rule, isNew: false)
    }

    private func presentEditSheet(rule: PortForwardRule, isNew: Bool) {
        DispatchQueue.main.async {
            guard let parent = NSApp.keyWindow else { return }
            presentPortForwardEditWindow(
                rule: rule,
                isNew: isNew,
                on: parent,
                onSave: { saved in
                    if isNew {
                        self.store.addRule(saved)
                    } else {
                        self.store.updateRule(saved)
                    }
                    self.editingRule = nil
                },
                onDismiss: {
                    self.editingRule = nil
                }
            )
        }
    }
}

// MARK: - 端口转发编辑页

struct PortForwardEditView: View {
    @ObservedObject private var sshStore = SSHStore.shared
    @State private var rule: PortForwardRule
    private let isNew: Bool
    private let onSave: (PortForwardRule) -> Void
    private let onDismiss: () -> Void

    init(
        rule: PortForwardRule,
        isNew: Bool,
        onSave: @escaping (PortForwardRule) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self._rule = State(initialValue: rule)
        self.isNew = isNew
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    typePicker
                    descriptionText
                    nameField
                    sshHostPicker
                    typeSpecificFields
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { onDismiss() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                Button("确定") {
                    onSave(rule)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!rule.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("转发类型")
                .font(.system(size: 13, weight: .medium))
            Picker("", selection: $rule.type) {
                ForEach(PortForwardType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var descriptionText: some View {
        Text(rule.type.description)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("规则")
                Text("*")
                    .foregroundColor(.red)
            }
            .font(.system(size: 13, weight: .medium))
            TextField("例如：访问远程 MySQL", text: $rule.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    private var sshHostPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("SSH 主机（跳板机）")
                Text("*")
                    .foregroundColor(.red)
            }
            .font(.system(size: 13, weight: .medium))

            Picker("", selection: $rule.sshConnectionID) {
                Text("选择主机")
                    .tag(UUID?.none)
                ForEach(sshStore.connections) { conn in
                    Text("\(conn.name) (\(conn.host):\(conn.port))")
                        .tag(Optional(conn.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var typeSpecificFields: some View {
        switch rule.type {
        case .local:
            localFields
        case .remote:
            remoteFields
        case .dynamic:
            dynamicFields
        }
    }

    private var localFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            portField(title: "本地监听端口", hint: "在本机 127.0.0.1 上监听此端口", value: Binding(
                get: { String(rule.localListenPort) },
                set: { rule.localListenPort = UInt16($0) ?? 0 }
            ))
            textField(title: "远端主机", value: $rule.remoteHost, hint: "远端主机相对于 SSH 主机可达（填 localhost 表示 SSH 主机自身）")
            portField(title: "远端端口", hint: "", value: Binding(
                get: { String(rule.remotePort) },
                set: { rule.remotePort = UInt16($0) ?? 0 }
            ))
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            portField(title: "本机服务端口", hint: "本机上运行的服务端口，流量将从 SSH 主机转发到此端口", value: Binding(
                get: { String(rule.localServicePort) },
                set: { rule.localServicePort = UInt16($0) ?? 0 }
            ))
            portField(title: "SSH 主机监听端口", hint: "SSH 主机将在 0.0.0.0 上监听并转发到本机", value: Binding(
                get: { String(rule.remotePort) },
                set: { rule.remotePort = UInt16($0) ?? 0 }
            ))
        }
    }

    private var dynamicFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("代理协议")
                    .font(.system(size: 13, weight: .medium))
                Picker("", selection: $rule.dynamicProtocol) {
                    ForEach(PortForwardDynamicProtocol.allCases) { proto in
                        Text(proto.displayName).tag(proto)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            portField(title: "本地代理端口", hint: "在本机 127.0.0.1 上监听 SOCKS5 代理端口", value: Binding(
                get: { String(rule.localListenPort) },
                set: { rule.localListenPort = UInt16($0) ?? 0 }
            ))
        }
    }

    private func textField(title: String, value: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                Text("*")
                    .foregroundColor(.red)
            }
            .font(.system(size: 13, weight: .medium))
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func portField(title: String, hint: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                Text("*")
                    .foregroundColor(.red)
            }
            .font(.system(size: 13, weight: .medium))
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}
