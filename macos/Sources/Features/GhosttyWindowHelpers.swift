import AppKit
import SwiftUI
import GhosttyKit

// MARK: - 通用半透明面板窗口

/// 与主终端窗口保持一致的辅助窗口基类：/// 三色灯标题栏半透明、支持 background-opacity / background-blur、
/// 仅关闭按钮可用（最小化/缩放按钮置灰）。
class GhosttyPanelWindow: NSWindow {
    init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable],
        config: Ghostty.Config?
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false

        // 标题栏透明化，让窗口背景色透上来。
        self.titlebarAppearsTransparent = true

        // 仅保留关闭按钮可用；最小化/缩放置灰（不隐藏，保持标准窗口观感）。
        standardWindowButton(.miniaturizeButton)?.isEnabled = false
        standardWindowButton(.zoomButton)?.isEnabled = false

        // 根据配置设置透明/磨砂背景。
        applyBackground(config: config)
    }

    /// 应用与主窗口一致的背景透明度和磨砂效果。
    func applyBackground(config: Ghostty.Config?) {
        let opacity = config?.backgroundOpacity ?? 1
        let blur = config?.backgroundBlur ?? .disabled
        let needsTransparency = opacity < 1 || blur.isGlassStyle
        guard needsTransparency else { return }

        self.isOpaque = false
        let baseColor = config.map { NSColor($0.backgroundColor) } ?? NSColor.windowBackgroundColor
        self.backgroundColor = baseColor.withAlphaComponent(opacity.clamped(to: 0.001...1))
    }

    override func cancelOperation(_ sender: Any?) {
        self.close()
    }
}

// MARK: - 模态窗口控制器

/// 标准的 macOS 模态窗口控制器：显示时阻塞父窗口交互，关闭后恢复。
/// 窗口默认居中于父窗口。
class ModalWindowController: NSWindowController, NSWindowDelegate {
    private let parentWindow: NSWindow?
    var onWindowClosed: (() -> Void)?

    init(window: NSWindow, parentWindow: NSWindow? = nil) {
        self.parentWindow = parentWindow
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 以模态方式显示窗口，默认居中于父窗口。
    func showModal() {
        guard let window else { return }
        window.centerRelative(to: parentWindow)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        onWindowClosed?()
    }
}

// MARK: - 窗口定位

extension NSWindow {
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
}

// MARK: - 背景模糊

extension NSWindow {
    /// 为窗口内容与容器配置与主终端窗口一致的背景模糊/磨砂效果。
    /// 注意：窗口本身的 backgroundColor 已在 GhosttyPanelWindow 中设置；
    /// 本方法负责追加玻璃效果视图或调用私有 API 设置模糊。
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
