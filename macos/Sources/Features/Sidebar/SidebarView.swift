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
    var onOpenConnection: ((SSHConnection) -> Void)?
    var onAddGroup: ((SSHGroup) -> Void)?
    var onSettings: (() -> Void)?

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
            .sidebarTooltip("Expand Sidebar".localized)

            Button(action: { onNewLocalTerminal?() }) {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .sidebarTooltip("New Local Terminal".localized)

            Spacer()
            Button(action: { onSettings?() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .frame(height: 32)
            .sidebarTooltip("Settings".localized)
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
            .sidebarTooltip(collapsed ? "Expand Sidebar".localized : "Collapse Sidebar".localized)
            .padding(.leading, 4)

            if !collapsed {
                Spacer()
                HStack(spacing: 2) {
                    Button(action: { showAddSSHDialog() }) {
                        Image(systemName: "plus.square").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("New SSH Connection".localized)

                    Button(action: { showAddTelnetDialog() }) {
                        Image(systemName: "network").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("New Telnet Connection".localized)

                    Button(action: { showAddGroupDialog() }) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("New Group".localized)

                    Button(action: { onNewLocalTerminal?() }) {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("New Local Terminal".localized)
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
                }.buttonStyle(.plain).sidebarTooltip("Clear Search".localized)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .cornerRadius(6)
    }

    // MARK: - 设置按钮

    private var settingsButton: some View {
        Button(action: { onSettings?() }) {
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
        .sidebarTooltip("Settings".localized)
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
                Text("Default (\(defaultCount))")
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
                            showDeleteGroupConfirmation(group)
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
            connectionTypeTag(conn.type)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpenConnection?(conn) }
        .contextMenu {
            Button("Edit") {
                editingConnection = conn
                if conn.type == .telnet {
                    showEditTelnetDialog()
                } else {
                    showEditSSHDialog()
                }
            }
            Button(role: .destructive) {
                showDeleteConnectionConfirmation(conn)
            } label: {
                Text("Delete")
                    .foregroundColor(.red)
            }
        }
    }

    /// 连接类型小标签：SSH 绿色，Telnet 橙色。
    private func connectionTypeTag(_ type: RemoteConnectionType) -> some View {
        let color: Color
        switch type {
        case .ssh: color = .green
        case .telnet: color = .orange
        }
        return Text(type.displayName)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color, lineWidth: 1)
            )
            .cornerRadius(3)
    }

    private func filtered(_ list: [SSHConnection]) -> [SSHConnection] {
        store.searchText.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(store.searchText) }
    }

    // MARK: - 弹窗

    private func showDeleteGroupConfirmation(_ group: SSHGroup) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Delete Group".localized
            alert.informativeText = L("Are you sure you want to delete group \"%@\"? Connections in this group will be moved to Ungrouped.", group.name)
            alert.addButton(withTitle: "Delete".localized)
            alert.addButton(withTitle: "Cancel".localized)
            alert.buttons.first?.hasDestructiveAction = true

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn {
                        store.removeGroup(group.id)
                    }
                }
            } else {
                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    store.removeGroup(group.id)
                }
            }
        }
    }

    private func showDeleteConnectionConfirmation(_ conn: SSHConnection) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Delete Connection".localized
            alert.informativeText = L("Are you sure you want to delete \"%@\"? This action cannot be undone.", conn.name)
            alert.addButton(withTitle: "Delete".localized)
            alert.addButton(withTitle: "Cancel".localized)
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
            message: "Input new group name",
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
            message: "Rename group to",
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

    private func showAddTelnetDialog() {
        DispatchQueue.main.async {
            guard let parent = NSApp.keyWindow else { return }
            let config = (NSApp.delegate as? AppDelegate)?.ghostty.config

            let controller = TelnetConfigWindowController(
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

    private func showEditTelnetDialog() {
        let conn = editingConnection
        DispatchQueue.main.async {
            guard let conn else { return }
            guard let parent = NSApp.keyWindow else { return }
            let config = (NSApp.delegate as? AppDelegate)?.ghostty.config

            let controller = TelnetConfigWindowController(
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
            Text("Port Forward".localized)
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search by keyword".localized, text: $searchText)
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
            Text("No port forwarding rules".localized)
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
                Button("Stop".localized) {
                    handleToggle(rule: rule)
                }
            }
            Button("Edit".localized) {
                showEditSheet(rule: rule)
            }
            Button("View Log".localized) {
                openPortForwardLog(rule: rule)
            }
            Button("Clear Log".localized) {
                store.clearLog(for: rule.id)
            }
            Button {
                showDeleteRuleConfirmation(rule)
            } label: {
                Text("Delete".localized)
                    .foregroundColor(.red)
            }
        }
    }

    private func showDeleteRuleConfirmation(_ rule: PortForwardRule) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Delete Port Forward".localized
            alert.informativeText = L("Are you sure you want to delete port forward rule \"%@\"? This action cannot be undone.", rule.name)
            alert.addButton(withTitle: "Delete".localized)
            alert.addButton(withTitle: "Cancel".localized)
            alert.buttons.first?.hasDestructiveAction = true

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn {
                        store.removeRule(rule.id)
                    }
                }
            } else {
                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    store.removeRule(rule.id)
                }
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

        guard let pid = ProcessInspector.pidListening(on: rule.localListenPort) else {
            store.startRule(rule.id)
            return
        }

        let process = ProcessInspector.processName(for: pid) ?? "Unknown Process".localized
        let alert = NSAlert()
        alert.messageText = L("Port %d is already in use", rule.localListenPort)
        alert.informativeText = L("Process: %@ (PID %d)\nTerminate this process and start port forwarding?", process, pid)
        alert.addButton(withTitle: "OK".localized)
        alert.addButton(withTitle: "Cancel".localized)

        let proceed = {
            if ProcessInspector.killProcess(pid: pid) {
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
        alert.messageText = "Unable to terminate process".localized
        alert.informativeText = L("Failed to terminate %@ (PID %d). Port forwarding could not start.", process, pid)
        alert.addButton(withTitle: "OK".localized)
        if let win = NSApp.keyWindow {
            alert.beginSheetModal(for: win) { _ in }
        } else {
            alert.runModal()
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
            Text(running ? "Running".localized : "Stopped".localized)
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
                Button("Cancel".localized) { onDismiss() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                Button("OK".localized) {
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
            Text("Forward Type".localized)
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
                Text("Rule".localized)
                Text("*")
                    .foregroundColor(.red)
            }
            .font(.system(size: 13, weight: .medium))
            TextField("e.g. Access remote MySQL".localized, text: $rule.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    private var sshHostPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("SSH Host (Jump)".localized)
                Text("*")
                    .foregroundColor(.red)
            }
            .font(.system(size: 13, weight: .medium))

            Picker("", selection: $rule.sshConnectionID) {
                Text("Select Host".localized)
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
            portField(title: "Local Listen Port".localized, hint: "Listen on this port at 127.0.0.1".localized, value: Binding(
                get: { String(rule.localListenPort) },
                set: { rule.localListenPort = UInt16($0) ?? 0 }
            ))
            textField(title: "Remote Host".localized, value: $rule.remoteHost, hint: "Remote host reachable from the SSH host (use localhost for the SSH host itself)".localized)
            portField(title: "Remote Port".localized, hint: "", value: Binding(
                get: { String(rule.remotePort) },
                set: { rule.remotePort = UInt16($0) ?? 0 }
            ))
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            portField(title: "Local Service Port".localized, hint: "Local service port; traffic from the SSH host will be forwarded here".localized, value: Binding(
                get: { String(rule.localServicePort) },
                set: { rule.localServicePort = UInt16($0) ?? 0 }
            ))
            portField(title: "SSH Host Listen Port".localized, hint: "SSH host will listen on 0.0.0.0 and forward to this machine".localized, value: Binding(
                get: { String(rule.remotePort) },
                set: { rule.remotePort = UInt16($0) ?? 0 }
            ))
        }
    }

    private var dynamicFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Proxy Protocol".localized)
                    .font(.system(size: 13, weight: .medium))
                Picker("", selection: $rule.dynamicProtocol) {
                    ForEach(PortForwardDynamicProtocol.allCases) { proto in
                        Text(proto.displayName).tag(proto)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            portField(title: "Local Proxy Port".localized, hint: "Listen for SOCKS5 proxy on this port at 127.0.0.1".localized, value: Binding(
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
