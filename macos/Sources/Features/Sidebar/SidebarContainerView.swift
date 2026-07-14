import AppKit
import SwiftUI
import Combine

/// 带左侧栏和右侧标签栏的终端视图容器
class SidebarTerminalTerminalViewContainer: TerminalViewContainer {
    // MARK: - 子视图

    fileprivate let sidebarHostingView: NSHostingView<SidebarView>
    fileprivate let sidebarBackgroundView = SidebarBackgroundView()
    fileprivate let tabBarHostingView: NSHostingView<TabBarView>
    fileprivate let dividerView = SidebarDividerView()

    private let tabDividerView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }()

    private let rightContainerView = NSView()

    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var tabGroupObserver: NSKeyValueObservation?
    private var tabWindowsObserver: NSKeyValueObservation?
    private var windowTitleNotif: NSObjectProtocol?
    private var windowDidBecomeKeyNotif: NSObjectProtocol?
    private var configCancellable: Any?
    private var tabBarViewID: Int = 0

    /// 标签组加入后重新应用外观的标记
    private var needsAppearanceRefresh: Bool = true

    private var _sidebarWidth: CGFloat = 250
    var sidebarWidth: CGFloat {
        get { _sidebarWidth }
        set {
            _sidebarWidth = max(150, min(newValue, 500))
            sidebarWidthConstraint?.constant = collapsed ? 32 : _sidebarWidth
            needsLayout = true
        }
    }

    private var _collapsed: Bool = false
    var collapsed: Bool {
        get { _collapsed }
        set {
            guard _collapsed != newValue else { return }
            _collapsed = newValue
            let width = newValue ? 32 : _sidebarWidth
            sidebarWidthConstraint?.constant = width
            rebuildSidebarView()
            needsLayout = true
        }
    }

    private weak var terminalContentView: NSView?
    private weak var terminalController: TerminalController?

    override var isOpaque: Bool { false }

    // MARK: - 初始化

    init<Root: View>(
        terminalController: TerminalController,
        @ViewBuilder rootView: () -> Root
    ) {
        self.terminalController = terminalController

        let config = terminalController.ghostty.config
        let backgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)

        let initialSidebar = SidebarView(
            collapsed: false,
            backgroundColor: backgroundColor,
            onToggleCollapse: nil,
            onNewLocalTerminal: nil,
            onNewPortForward: nil,
            onOpenSSH: nil
        )
        self.sidebarHostingView = NSHostingView(rootView: initialSidebar)
        self.sidebarHostingView.wantsLayer = true
        self.sidebarHostingView.layerContentsRedrawPolicy = .duringViewResize
        self.sidebarHostingView.layer?.needsDisplayOnBoundsChange = true

        self.sidebarBackgroundView.backgroundColor = backgroundColor
        self.sidebarBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        let initialTabBar = TabBarView(
            viewID: 0,
            windows: [],
            selectedWindow: nil,
            backgroundColor: backgroundColor,
            onSelectTab: nil,
            onCloseTab: nil
        )
        self.tabBarHostingView = NSHostingView(rootView: initialTabBar)
        self.tabBarHostingView.wantsLayer = true
        self.tabBarHostingView.layer?.backgroundColor = backgroundColor.cgColor
        self.tabBarHostingView.layer?.drawsAsynchronously = false
        self.tabBarHostingView.layer?.allowsEdgeAntialiasing = false
        self.tabBarHostingView.layer?.masksToBounds = true
        self.tabBarHostingView.layer?.shouldRasterize = false
        self.tabBarHostingView.layer?.allowsGroupOpacity = false

        self.rightContainerView.wantsLayer = true
        self.rightContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        self.rightContainerView.layer?.masksToBounds = true

        super.init(rootView: rootView)

        setupViews()
        setupConfigObserver()

        DispatchQueue.main.async { [weak self] in
            self?.setupObservers()
            self?.rebuildSidebarView()
            self?.rebuildTabBar()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        tabGroupObserver?.invalidate()
        tabWindowsObserver?.invalidate()
        if let obs = windowTitleNotif { NotificationCenter.default.removeObserver(obs) }
        if let obs = windowDidBecomeKeyNotif { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - 配置变化监听

    private func setupConfigObserver() {
        configCancellable = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshFromConfig()
        }
    }

    private func refreshFromConfig() {
        guard let tc = terminalController else { return }
        let config = tc.ghostty.config
        // 重新应用窗口外观
        if let window = self.window as? TerminalWindow {
            let dc = Ghostty.SurfaceView.DerivedConfig(config)
            window.syncAppearance(dc)
        }
        rebuildSidebarView()
        rebuildTabBar()
    }

    // MARK: - 视图生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil {
            refreshFromConfig()
        }
    }

    // MARK: - 视图设置

    private func setupViews() {
        terminalContentView = subviews.first
        if let tv = terminalContentView { tv.removeFromSuperview() }

        dividerView.container = self

        addSubview(sidebarBackgroundView)
        [sidebarHostingView, dividerView, rightContainerView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        [tabBarHostingView, tabDividerView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rightContainerView.addSubview($0)
        }

        if let tv = terminalContentView {
            tv.translatesAutoresizingMaskIntoConstraints = false
            rightContainerView.addSubview(tv)
        }

        setupConstraints()
    }

    private func setupConstraints() {
        guard let tv = terminalContentView else { return }

        let swc = sidebarHostingView.widthAnchor.constraint(equalToConstant: _sidebarWidth)
        swc.priority = .defaultHigh
        self.sidebarWidthConstraint = swc

        NSLayoutConstraint.activate([
            sidebarBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            sidebarBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarBackgroundView.widthAnchor.constraint(equalTo: sidebarHostingView.widthAnchor),

            sidebarHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHostingView.topAnchor.constraint(equalTo: topAnchor),
            sidebarHostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            swc,

            dividerView.leadingAnchor.constraint(equalTo: sidebarHostingView.trailingAnchor),
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 4),

            rightContainerView.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor),
            rightContainerView.topAnchor.constraint(equalTo: topAnchor),
            rightContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            tabBarHostingView.topAnchor.constraint(equalTo: rightContainerView.topAnchor),
            tabBarHostingView.leadingAnchor.constraint(equalTo: rightContainerView.leadingAnchor),
            tabBarHostingView.trailingAnchor.constraint(equalTo: rightContainerView.trailingAnchor),
            tabBarHostingView.heightAnchor.constraint(equalToConstant: 28),

            tabDividerView.topAnchor.constraint(equalTo: tabBarHostingView.bottomAnchor),
            tabDividerView.leadingAnchor.constraint(equalTo: rightContainerView.leadingAnchor),
            tabDividerView.trailingAnchor.constraint(equalTo: rightContainerView.trailingAnchor),
            tabDividerView.heightAnchor.constraint(equalToConstant: 1),

            tv.topAnchor.constraint(equalTo: tabDividerView.bottomAnchor),
            tv.leadingAnchor.constraint(equalTo: rightContainerView.leadingAnchor),
            tv.bottomAnchor.constraint(equalTo: rightContainerView.bottomAnchor),
            tv.trailingAnchor.constraint(equalTo: rightContainerView.trailingAnchor),
        ])
    }

    // MARK: - 观察者

    private func setupObservers() {
        guard let window = self.window else { return }

        tabGroupObserver = window.observe(\.tabGroup, options: [.initial, .new]) { [weak self] (win, _) in
            guard let self else { return }
            if let tg = win.tabGroup {
                let weakSelf = self
                self.tabWindowsObserver = tg.observe(\.windows, options: [.initial, .new]) { (_, _) in
                    DispatchQueue.main.async {
                        weakSelf.rebuildTabBar()
                        // 窗口加入标签组后刷新外观（macOS 可能覆盖了 isOpaque 等属性）
                        weakSelf.refreshFromConfig()
                    }
                }
            } else {
                self.tabWindowsObserver?.invalidate()
                self.tabWindowsObserver = nil
                DispatchQueue.main.async { self.rebuildTabBar() }
            }
        }

        windowTitleNotif = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSWindowDidChangeTitleNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildTabBar() }

        windowDidBecomeKeyNotif = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildTabBar() }
    }

    // MARK: - 标签栏

    func rebuildTabBar() {
        guard let window = self.window else { return }
        guard let config = terminalController?.ghostty.config else { return }
        tabBarViewID &+= 1
        let windows: [NSWindow]
        let selected: NSWindow?
        if let tg = window.tabGroup {
            windows = tg.windows
            selected = tg.selectedWindow
        } else {
            windows = [window]
            selected = window
        }

        let backgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)

        let newBar = TabBarView(
            viewID: tabBarViewID,
            windows: windows,
            selectedWindow: selected,
            backgroundColor: backgroundColor,
            onSelectTab: { target in
                target.makeKeyAndOrderFront(nil)
                if let tg = window.tabGroup { tg.selectedWindow = target }
            },
            onCloseTab: { target in target.close() }
        )
        tabBarHostingView.rootView = newBar
        tabBarHostingView.layer?.backgroundColor = backgroundColor.cgColor
    }

    // MARK: - 侧边栏

    func rebuildSidebarView() {
        guard let tc = terminalController else { return }
        let collapsed = self._collapsed
        let config = tc.ghostty.config

        let backgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)

        let newSidebar = SidebarView(
            collapsed: collapsed,
            backgroundColor: backgroundColor,
            onToggleCollapse: { [weak self] in self?.collapsed.toggle() },
            onNewLocalTerminal: { [weak tc] in
                guard let tc, let window = tc.window else { return }
                _ = TerminalController.newTab(tc.ghostty, from: window)
            },
            onNewPortForward: {
                let alert = NSAlert()
                alert.messageText = "Port Forwarding"
                alert.informativeText = "Not yet implemented."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            },
            onOpenSSH: { [weak tc] conn in
                guard let tc, let window = tc.window else { return }
                var cfg = Ghostty.SurfaceConfiguration()

                if conn.authMode == .password, !conn.password.isEmpty {
                    // 密码登录：用 expect 脚本自动输入密码，避免终端再提示用户
                    let expectScript = """
                    set timeout 15
                    set password $env(SSHPASS)
                    log_user 0
                    spawn /usr/bin/ssh \(conn.sshBaseArgs)
                    expect {
                        -nocase "password:" { send "$password\\r" }
                        timeout { }
                        eof { catch wait result; exit [lindex $result 3] }
                    }
                    sleep 0.5
                    puts "\\033\\[2J\\033\\[H\\033\\[3J"
                    log_user 1
                    send "\\r"
                    interact
                    """

                    let scriptURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ghostty_ssh_\(conn.id.uuidString).exp")

                    do {
                        try expectScript.write(to: scriptURL, atomically: true, encoding: .utf8)
                        cfg.command = "/usr/bin/expect \(scriptURL.path)"
                        cfg.environmentVariables["SSHPASS"] = conn.password
                    } catch {
                        // 写入失败时回退到普通 ssh 命令
                        cfg.command = conn.sshCommand
                    }
                } else {
                    cfg.command = conn.sshCommand
                }

                // 应用终端编码环境变量
                for (key, value) in conn.terminalEnvironment {
                    cfg.environmentVariables[key] = value
                }

                // X11 转发需要本地 DISPLAY / XAUTHORITY / PATH 环境变量
                if conn.x11Forwarding {
                    for (key, value) in SSHX11Environment.current {
                        cfg.environmentVariables[key] = value
                    }
                }

                let ctrl = TerminalController.newTab(tc.ghostty, from: window, withBaseConfig: cfg)
                if let ctrl {
                    ctrl.baseTitle = conn.name
                    ctrl.titleOverride = conn.name
                    DispatchQueue.main.async {
                        (ctrl.window?.contentView as? SidebarTerminalTerminalViewContainer)?.rebuildTabBar()
                    }
                }
            }
        )
        sidebarHostingView.rootView = newSidebar
        sidebarBackgroundView.backgroundColor = backgroundColor
    }
}

// MARK: - 扩展

extension BaseTerminalController {
    var sidebarTerminalContainer: SidebarTerminalTerminalViewContainer? {
        window?.contentView as? SidebarTerminalTerminalViewContainer
    }
}

// MARK: - 分隔线

class SidebarDividerView: NSView {
    weak var container: SidebarTerminalTerminalViewContainer?

    override func mouseDown(with event: NSEvent) {
        guard let container, let window = container.window else { return }
        let initialWidth = container.sidebarWidth
        let initialX = event.locationInWindow.x
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { ev, stop in
            guard let ev else { return }
            if ev.type == .leftMouseUp {
                stop.pointee = true
                // 拖动过程中不 live-resize，松手时一次性设置最终宽度并整体刷新。
                container.sidebarWidth = initialWidth + ev.locationInWindow.x - initialX
                container.layoutSubtreeIfNeeded()
                container.rebuildSidebarView()
                container.layoutSubtreeIfNeeded()
                container.display()
                return
            }
            // 拖动过程中只跟踪鼠标，不更新宽度
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        let mx = dirtyRect.midX
        ctx.move(to: CGPoint(x: mx, y: dirtyRect.minY))
        ctx.addLine(to: CGPoint(x: mx, y: dirtyRect.maxY))
        ctx.strokePath()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

// MARK: - 背景视图

/// 负责绘制侧边栏背景色的 layer-backed NSView。
/// 使用 CALayer 的 `backgroundColor` 直接填充，避免 resize 时 `draw(_:)` 只覆盖旧 bounds 导致新区域露出未初始化像素（白色竖线）。
class SidebarBackgroundView: NSView {
    var backgroundColor: NSColor = .clear {
        didSet {
            layer?.backgroundColor = backgroundColor.cgColor
        }
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.masksToBounds = true
    }
}
