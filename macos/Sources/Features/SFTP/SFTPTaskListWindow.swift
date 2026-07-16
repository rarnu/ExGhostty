import AppKit
import SwiftUI
import GhosttyKit

/// SFTP 任务列表独立窗口，支持与主终端窗口一致的 background-opacity 与 background-blur。
final class SFTPTaskListWindowController: NSWindowController, NSWindowDelegate {
    private let connection: SSHConnection?
    private let config: Ghostty.Config?
    var onWindowClosed: (() -> Void)?

    init(
        connection: SSHConnection?,
        config: Ghostty.Config?,
        parentWindow: NSWindow? = nil,
        onWindowClosed: (() -> Void)? = nil
    ) {
        self.connection = connection
        self.config = config
        self.onWindowClosed = onWindowClosed

        let window = SFTPTaskListWindow(config: config)
        super.init(window: window)
        window.delegate = self

        let contentView = SFTPTaskListView(connection: connection)
            .frame(minWidth: 700, minHeight: 450)
            // 保持根视图背景透明，让窗口级背景/模糊效果透出来。
            .background(Color.clear)

        let hostingView = NSHostingView(rootView: contentView)
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
        window.title = "Transfer Tasks".localized
        window.centerRelative(to: parentWindow)

        // 配置与主窗口一致的背景模糊。
        window.configureBackgroundBlur(config: config, container: container)

        // 监听 ESC 键，确保即使 SwiftUI 列表持有焦点也能关闭窗口。
        setupEscapeMonitor()
    }

    deinit {
        if let monitor = escapeEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private var escapeEventMonitor: Any?

    private func setupEscapeMonitor() {
        escapeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 是 ESC 的虚拟键码。
            guard event.keyCode == 53 else { return event }
            self?.window?.close()
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// 任务列表窗口：永远在最前，但非模态。
private final class SFTPTaskListWindow: GhosttyPanelWindow {
    init(config: Ghostty.Config?) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            config: config
        )

        self.minSize = NSSize(width: 700, height: 450)

        // 永远在最前，但不阻塞父窗口。
        self.level = .floating
        self.collectionBehavior = [.moveToActiveSpace, .transient]
    }
}
