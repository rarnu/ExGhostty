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

// MARK: - SSH 配置专用 Sheet 窗口

/// 强制可成为 keyWindow，并显式将 Cmd+A/C/V/X 路由给 first responder，
/// 以修复 AppKit sheet 中 SwiftUI 输入框无法复制粘贴的问题。
final class SSHConfigSheetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector?
        switch event.keyCode {
        case 0:  selector = NSSelectorFromString("selectAll:")
        case 7:  selector = NSSelectorFromString("cut:")
        case 8:  selector = NSSelectorFromString("copy:")
        case 9:  selector = NSSelectorFromString("paste:")
        default: selector = nil
        }

        if let selector, NSApp.sendAction(selector, to: nil, from: self) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

/// 创建并呈现 SSH 配置 sheet
func presentSSHConfigSheet<Content: View>(
    _ view: Content,
    title: String,
    on parent: NSWindow
) {
    let hostView = NSHostingView(rootView: view)
    let vc = NSViewController()
    vc.view = hostView

    let sheet = SSHConfigSheetWindow(contentViewController: vc)
    sheet.title = title
    sheet.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    sheet.titlebarAppearsTransparent = true
    sheet.titleVisibility = .hidden
    sheet.standardWindowButton(.closeButton)?.isHidden = true
    sheet.standardWindowButton(.miniaturizeButton)?.isHidden = true
    sheet.standardWindowButton(.zoomButton)?.isHidden = true
    sheet.isMovableByWindowBackground = true
    sheet.setContentSize(NSSize(width: 520, height: 620))
    sheet.isReleasedWhenClosed = false

    parent.beginSheet(sheet) { _ in }
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
    /// 与终端保持一致的背景色（已包含 background-opacity alpha）
    let backgroundColor: NSColor

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

            Button(action: { onNewPortForward?() }) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .sidebarTooltip("端口转发")

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

                    Button(action: { onNewPortForward?() }) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundColor(.secondary).frame(width: 22, height: 22)
                    }.buttonStyle(.plain).sidebarTooltip("端口转发")
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
            Button("Delete", role: .destructive) {
                showDeleteConnectionConfirmation(conn)
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

            let view = EditSSHView(
                connection: conn,
                sshStore: SSHStore.shared,
                onSave: { updated in
                    SSHStore.shared.updateConnection(updated)
                },
                onDismiss: { [weak parent] in
                    guard let parent, let sheet = parent.attachedSheet else { return }
                    parent.endSheet(sheet)
                }
            )
            presentSSHConfigSheet(view, title: "编辑主机", on: parent)
        }
    }

    private func showAddSSHDialog() {
        DispatchQueue.main.async {
            guard let parent = NSApp.keyWindow else { return }

            let view = AddSSHView(
                sshStore: SSHStore.shared,
                onSave: { conn in
                    SSHStore.shared.addConnection(conn)
                },
                onDismiss: { [weak parent] in
                    guard let parent, let sheet = parent.attachedSheet else { return }
                    parent.endSheet(sheet)
                }
            )
            presentSSHConfigSheet(view, title: "创建主机", on: parent)
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
            Button("Delete", role: .destructive, action: { onDelete?() })
        }
    }
}
