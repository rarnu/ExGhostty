import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

/// “关于”窗口控制器：模态显示，与主窗口一致的半透明/磨砂背景，仅关闭按钮可用。
class AboutController: NSWindowController, NSWindowDelegate {
    static let shared: AboutController = AboutController()

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Functions

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config

        let panel = GhosttyPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            config: config
        )
        panel.title = "About ExGhostty".localized
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let hosting = NSHostingView(rootView: AboutView(onClose: { [weak panel] in
            panel?.close()
        }))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.configureBackgroundBlur(config: config, container: hosting)

        window = panel

        // 以模态方式显示：阻塞直到窗口关闭。
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
    }

    func hide() {
        window?.close()
    }

    // MARK: - First Responder

    @IBAction func close(_ sender: Any) {
        window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        window?.performClose(sender)
    }

    /// ESC 关闭窗口。
    @objc func cancel(_ sender: Any?) {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
        window = nil
    }
}
