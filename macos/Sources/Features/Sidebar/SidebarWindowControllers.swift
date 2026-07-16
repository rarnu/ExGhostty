import AppKit
import SwiftUI
import GhosttyKit

// MARK: - SSH 配置窗口（新建/编辑）

/// 标准的 macOS 模态窗口，用于新建或编辑 SSH 连接。
/// 标题栏半透明、三色灯、仅关闭按钮可用。
final class SSHConfigWindowController: ModalWindowController {
    init(
        mode: SSHConfigFormView.Mode,
        sshStore: SSHStore,
        config: Ghostty.Config?,
        parentWindow: NSWindow? = nil,
        onSave: @escaping (SSHConnection) -> Void
    ) {
        let title: String
        switch mode {
        case .add: title = "创建主机"
        case .edit: title = "编辑主机"
        }

        let window = GhosttyPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            config: config
        )
        window.minSize = NSSize(width: 520, height: 560)
        window.title = title
        window.isReleasedWhenClosed = false

        super.init(window: window, parentWindow: parentWindow)

        let view = SSHConfigFormView(
            mode: mode,
            sshStore: sshStore,
            onSave: { conn in
                onSave(conn)
                self.close()
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        window.contentView = container
        window.configureBackgroundBlur(config: config, container: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// MARK: - 分组名称输入窗口

/// 标准的 macOS 模态窗口，用于输入单个名称（新建分组、tmux/zellij 会话、代码片段分类等）。
final class GroupNameWindowController: ModalWindowController {
    private let textField = NSTextField()
    private let filter: ((String) -> String)?
    private let completion: (String?) -> Void
    private var didComplete = false

    init(
        title: String,
        message: String? = nil,
        placeholder: String = "",
        defaultText: String = "",
        confirmTitle: String = "确认",
        cancelTitle: String = "取消",
        filter: ((String) -> String)? = nil,
        config: Ghostty.Config?,
        parentWindow: NSWindow? = nil,
        completion: @escaping (String?) -> Void
    ) {
        self.filter = filter
        self.completion = completion

        let window = GhosttyPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            config: config
        )
        window.minSize = NSSize(width: 320, height: 150)
        window.title = title
        window.isReleasedWhenClosed = false

        super.init(window: window, parentWindow: parentWindow)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let labelText = message ?? title
        let label = NSTextField(labelWithString: labelText)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        textField.placeholderString = placeholder
        textField.stringValue = defaultText
        textField.bezelStyle = .roundedBezel
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.delegate = self

        let addButton = NSButton(title: confirmTitle, target: self, action: #selector(confirm))
        addButton.keyEquivalent = "\r"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: cancelTitle, target: self, action: #selector(cancel))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(label)
        contentView.addSubview(textField)
        contentView.addSubview(addButton)
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            textField.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            textField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            addButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            addButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        window.contentView = contentView
        window.initialFirstResponder = textField
        window.configureBackgroundBlur(config: config, container: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func confirm() {
        guard !didComplete else { return }
        didComplete = true
        let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        completion(value.isEmpty ? nil : value)
        close()
    }

    @objc private func cancel() {
        guard !didComplete else { return }
        didComplete = true
        completion(nil)
        close()
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        if !didComplete {
            didComplete = true
            completion(nil)
        }
    }
}

extension GroupNameWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let filter = filter else { return }
        guard let field = obj.object as? NSTextField else { return }
        let filtered = filter(field.stringValue)
        if filtered != field.stringValue {
            field.stringValue = filtered
        }
    }
}

// MARK: - 端口转发编辑入口

/// 弹出端口转发规则创建/编辑窗口（标准 macOS 模态窗口，带三色灯，仅关闭可用）。
func presentPortForwardEditWindow(
    rule: PortForwardRule,
    isNew: Bool,
    on parent: NSWindow,
    onSave: @escaping (PortForwardRule) -> Void,
    onDismiss: @escaping () -> Void
) {
    guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
    let controller = PortForwardEditWindowController(
        config: appDelegate.ghostty.config,
        rule: rule,
        isNew: isNew,
        parentWindow: parent,
        onSave: onSave,
        onDismiss: onDismiss
    )
    controller.showModal()
}
