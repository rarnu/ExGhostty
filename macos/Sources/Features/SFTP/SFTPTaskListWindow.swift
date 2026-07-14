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
        window.title = "传输任务"
        window.centerRelative(to: parentWindow)

        // 配置与主窗口一致的背景模糊。
        window.configureBackgroundBlur(config: config, container: container)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// 任务列表窗口。
private final class SFTPTaskListWindow: NSWindow {
    init(config: Ghostty.Config?) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.minSize = NSSize(width: 700, height: 450)

        // 只允许使用关闭按钮，最小化/缩放按钮置为不可用。
        standardWindowButton(.miniaturizeButton)?.isEnabled = false
        standardWindowButton(.zoomButton)?.isEnabled = false

        // 根据配置设置窗口透明背景，与 TerminalWindow 保持一致。
        let opacity = config?.backgroundOpacity ?? 1
        let blur = config?.backgroundBlur ?? .disabled
        let needsTransparency = opacity < 1 || blur.isGlassStyle
        guard needsTransparency else { return }

        self.isOpaque = false
        // 使用配置背景色作为底色（主窗口由终端 surface 提供颜色，任务窗口没有 surface，直接用配置色）。
        let baseColor = config.map { NSColor($0.backgroundColor) } ?? NSColor.windowBackgroundColor
        self.backgroundColor = baseColor.withAlphaComponent(opacity.clamped(to: 0.001...1))
    }

    override func cancelOperation(_ sender: Any?) {
        self.close()
    }
}

// MARK: - 背景模糊与窗口定位

private extension NSWindow {
    /// 相对于指定父窗口居中；无父窗口时回退到屏幕居中。
    func centerRelative(to parentWindow: NSWindow?) {
        guard let parentWindow, let screen = parentWindow.screen else {
            self.center()
            return
        }

        let parentFrame = parentWindow.frame
        let windowSize = self.frame.size
        var origin = NSPoint(
            x: parentFrame.midX - windowSize.width / 2,
            y: parentFrame.midY - windowSize.height / 2
        )

        // 确保窗口不会超出当前屏幕可见区域。
        let visibleFrame = screen.visibleFrame
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - windowSize.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - windowSize.height)

        self.setFrameOrigin(origin)
    }

    func configureBackgroundBlur(config: Ghostty.Config?, container: NSView) {
        let opacity = config?.backgroundOpacity ?? 1
        let blur = config?.backgroundBlur ?? .disabled
        let needsTransparency = opacity < 1 || blur.isGlassStyle
        guard needsTransparency else { return }

        if blur.isGlassStyle {
            addGlassEffect(config: config, container: container)
        } else if blur.isEnabled {
            // 非玻璃磨砂：使用与 TerminalWindow 相同的私有 API 设置窗口背景模糊。
            guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
            ghostty_set_window_background_blur(
                appDelegate.ghostty.app,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    private func addGlassEffect(config: Ghostty.Config?, container: NSView) {
        guard #available(macOS 26.0, *) else { return }
        guard let config else { return }

        let style: NSGlassEffectView.Style
        switch config.backgroundBlur {
        case .macosGlassClear:
            style = .clear
        default:
            style = .regular
        }

        let glassView = NSGlassEffectView()
        glassView.style = style
        glassView.tintColor = NSColor(config.backgroundColor).withAlphaComponent(config.backgroundOpacity)
        glassView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(glassView, positioned: .below, relativeTo: container.subviews.first)
        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: container.topAnchor),
            glassView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glassView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glassView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
