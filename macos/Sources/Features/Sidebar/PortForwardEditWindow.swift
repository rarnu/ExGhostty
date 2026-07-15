import AppKit
import SwiftUI
import GhosttyKit

// MARK: - 端口转发规则编辑窗口

/// 端口转发规则创建/编辑窗口控制器。
/// 标准 macOS 窗口（带三色灯），仅关闭按钮可用，支持 ESC 关闭，
/// 背景透明/磨砂效果与主窗口一致。
final class PortForwardEditWindowController: ModalWindowController {
    private static var activeControllers = NSHashTable<PortForwardEditWindowController>(options: .strongMemory)

    private let onSave: (PortForwardRule) -> Void
    private let onDismiss: () -> Void

    init(
        config: Ghostty.Config,
        rule: PortForwardRule,
        isNew: Bool,
        parentWindow: NSWindow? = nil,
        onSave: @escaping (PortForwardRule) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onDismiss = onDismiss

        let contentHeight: CGFloat
        switch rule.type {
        case .local: contentHeight = 580
        case .remote, .dynamic: contentHeight = 500
        }

        let window = PortForwardEditWindow(config: config, contentHeight: contentHeight)
        super.init(window: window, parentWindow: parentWindow)
        Self.activeControllers.add(self)

        let view = PortForwardEditView(
            rule: rule,
            isNew: isNew,
            onSave: { [weak self] saved in
                self?.onSave(saved)
                self?.close()
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )
        .frame(width: 520)

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
        window.title = "端口转发配置"
        window.configureBackgroundBlur(config: config, container: container)
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        Self.activeControllers.remove(self)
        onDismiss()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class PortForwardEditWindow: GhosttyPanelWindow {
    init(config: Ghostty.Config, contentHeight: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: contentHeight),
            config: config
        )

        self.minSize = NSSize(width: 520, height: contentHeight)
    }
}
