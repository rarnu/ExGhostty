import AppKit
import SwiftUI
import Combine

/// 带左侧栏和右侧标签栏的终端视图容器
/// 布局:
/// ┌──────────┬────────────────────────────┐
/// │ sidebar  │ [Tab Bar: Tabs | +]        │
/// │ (玻璃)   ├────────────────────────────┤
/// │          │    Terminal Content         │
/// └──────────┴────────────────────────────┘
class SidebarTerminalTerminalViewContainer: TerminalViewContainer {
    // MARK: - 子视图

    /// 侧边栏的 NSHostingView
    private let sidebarHostingView: NSHostingView<SidebarView>

    /// 侧边栏磨砂玻璃背景
    private let sidebarVisualEffectView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        v.autoresizingMask = [.width, .height]
        return v
    }()

    /// 标签栏的 NSHostingView
    private let tabBarHostingView: NSHostingView<TabBarView>

    /// 分隔线（侧边栏和右侧容器之间）
    private let dividerView = SidebarDividerView()

    /// 分隔线（标签栏和终端之间）
    private let tabDividerView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }()

    /// 右侧容器（标签栏 + 终端）
    private let rightContainerView = NSView()

    /// 侧边栏宽度约束
    private var sidebarWidthConstraint: NSLayoutConstraint?

    /// tabGroup 的 KVO
    private var tabGroupObserver: NSKeyValueObservation?
    private var tabWindowsObserver: NSKeyValueObservation?
    private var windowTitleNotif: NSObjectProtocol?
    private var windowDidBecomeKeyNotif: NSObjectProtocol?

    /// 配置通知观察者
    private var configCancellable: Any?

    /// 标签栏刷新计数器（每次重建递增，强制 SwiftUI 重新渲染）
    private var tabBarViewID: Int = 0

    /// 侧边栏宽度
    private var _sidebarWidth: CGFloat = 250
    var sidebarWidth: CGFloat {
        get { _sidebarWidth }
        set {
            _sidebarWidth = max(150, min(newValue, 500))
            sidebarWidthConstraint?.constant = collapsed ? 0 : _sidebarWidth
            needsLayout = true
        }
    }

    /// 折叠状态
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

    /// 当前配置值
    private var configBackgroundOpacity: Double = 1.0
    private var configHasBlur: Bool = false

    /// 终端视图（来自父类）
    private weak var terminalContentView: NSView?

    /// 弱引用 TerminalController
    private weak var terminalController: TerminalController?

    // MARK: - 初始化

    init<Root: View>(
        terminalController: TerminalController,
        @ViewBuilder rootView: () -> Root
    ) {
        self.terminalController = terminalController

        // 读取配置
        let config = terminalController.ghostty.config
        let opacity = config.backgroundOpacity
        let blur = config.backgroundBlur
        self.configBackgroundOpacity = opacity
        self.configHasBlur = opacity < 1 || blur.isGlassStyle

        let initialSidebar = SidebarView(
            collapsed: false,
            backgroundOpacity: opacity,
            hasBlur: configHasBlur,
            onToggleCollapse: nil,
            onNewLocalTerminal: nil,
            onNewPortForward: nil,
            onOpenSSH: nil
        )
        self.sidebarHostingView = NSHostingView(rootView: initialSidebar)

        let initialTabBar = TabBarView(
            viewID: 0,
            windows: [],
            selectedWindow: nil,
            backgroundOpacity: opacity,
            onSelectTab: nil,
            onCloseTab: nil
        )
        self.tabBarHostingView = NSHostingView(rootView: initialTabBar)

        super.init(rootView: rootView)

        setupViews()
        setupConfigObserver()

        // 延迟设置观察者（window 可能还没就绪）
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
        if let obs = windowTitleNotif {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = windowDidBecomeKeyNotif {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - 配置变化监听

    private func setupConfigObserver() {
        configCancellable = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let tc = self.terminalController else { return }
            let config = tc.ghostty.config
            self.configBackgroundOpacity = config.backgroundOpacity
            self.configHasBlur = config.backgroundOpacity < 1 || config.backgroundBlur.isGlassStyle
            self.updateVisualEffects()
            self.rebuildSidebarView()
            self.rebuildTabBar()
        }
    }

    private func updateVisualEffects() {
        let needsEffect = configHasBlur
        sidebarVisualEffectView.isHidden = !needsEffect
        if needsEffect {
            sidebarVisualEffectView.alphaValue = max(0.1, configBackgroundOpacity)
        }
    }

    // MARK: - 视图设置

    private func setupViews() {
        terminalContentView = subviews.first
        if let tv = terminalContentView {
            tv.removeFromSuperview()
        }

        // 构建层级:
        // self → [sidebarVibrancy, sidebar, divider, rightContainer]
        // rightContainer → [tabBar, tabDivider, terminal]

        // 侧边栏玻璃背景
        sidebarVisualEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebarVisualEffectView)
        updateVisualEffects()

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

        let tabBarHeight: CGFloat = 28

        NSLayoutConstraint.activate([
            // 玻璃背景：与侧边栏同位置
            sidebarVisualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarVisualEffectView.topAnchor.constraint(equalTo: topAnchor),
            sidebarVisualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarVisualEffectView.trailingAnchor.constraint(equalTo: sidebarHostingView.trailingAnchor),

            // 侧边栏
            sidebarHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarHostingView.topAnchor.constraint(equalTo: topAnchor),
            sidebarHostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            swc,

            // 分隔线
            dividerView.leadingAnchor.constraint(equalTo: sidebarHostingView.trailingAnchor),
            dividerView.topAnchor.constraint(equalTo: topAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 4),

            // 右侧容器
            rightContainerView.leadingAnchor.constraint(equalTo: dividerView.trailingAnchor),
            rightContainerView.topAnchor.constraint(equalTo: topAnchor),
            rightContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // 标签栏（右侧容器顶部）
            tabBarHostingView.topAnchor.constraint(equalTo: rightContainerView.topAnchor),
            tabBarHostingView.leadingAnchor.constraint(equalTo: rightContainerView.leadingAnchor),
            tabBarHostingView.trailingAnchor.constraint(equalTo: rightContainerView.trailingAnchor),
            tabBarHostingView.heightAnchor.constraint(equalToConstant: tabBarHeight),

            // 标签栏分隔线
            tabDividerView.topAnchor.constraint(equalTo: tabBarHostingView.bottomAnchor),
            tabDividerView.leadingAnchor.constraint(equalTo: rightContainerView.leadingAnchor),
            tabDividerView.trailingAnchor.constraint(equalTo: rightContainerView.trailingAnchor),
            tabDividerView.heightAnchor.constraint(equalToConstant: 1),

            // 终端视图（填满剩余空间）
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
                    DispatchQueue.main.async { weakSelf.rebuildTabBar() }
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

    // MARK: - 标签栏管理

    func rebuildTabBar() {
        guard let window = self.window else { return }

        tabBarViewID &+= 1  // 递增 ID 防止 SwiftUI 跳过渲染

        let windows: [NSWindow]
        let selected: NSWindow?

        if let tg = window.tabGroup {
            windows = tg.windows
            selected = tg.selectedWindow
        } else {
            windows = [window]
            selected = window
        }

        let newBar = TabBarView(
            viewID: tabBarViewID,
            windows: windows,
            selectedWindow: selected,
            backgroundOpacity: configBackgroundOpacity,
            onSelectTab: { target in
                target.makeKeyAndOrderFront(nil)
                if let tg = window.tabGroup { tg.selectedWindow = target }
            },
            onCloseTab: { target in
                target.close()
            }
        )
        tabBarHostingView.rootView = newBar
    }

    // MARK: - 侧边栏管理

    func rebuildSidebarView() {
        let tc = terminalController
        let collapsed = self._collapsed
        let opacity = configBackgroundOpacity
        let blur = configHasBlur

        let newSidebar = SidebarView(
            collapsed: collapsed,
            backgroundOpacity: opacity,
            hasBlur: blur,
            onToggleCollapse: { [weak self] in
                self?.collapsed.toggle()
            },
            onNewLocalTerminal: { [weak tc] in
                guard let tc, let window = tc.window else { return }
                _ = TerminalController.newTab(tc.ghostty, from: window)
            },
            onNewPortForward: {
                let alert = NSAlert()
                alert.messageText = "Port Forwarding"
                alert.informativeText = "Port forwarding feature is not yet implemented."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            },
            onOpenSSH: { [weak tc] conn in
                guard let tc, let window = tc.window else { return }
                var config = Ghostty.SurfaceConfiguration()
                config.command = conn.sshCommand
                // 设置 SSH 标签初始标题为连接名称
                let ctrl = TerminalController.newTab(tc.ghostty, from: window, withBaseConfig: config)
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
    }
}

// MARK: - 扩展

extension BaseTerminalController {
    var sidebarTerminalContainer: SidebarTerminalTerminalViewContainer? {
        window?.contentView as? SidebarTerminalTerminalViewContainer
    }
}

// MARK: - 分隔线视图

class SidebarDividerView: NSView {
    weak var container: SidebarTerminalTerminalViewContainer?

    override func mouseDown(with event: NSEvent) {
        guard let container else { return }
        guard let window = container.window else { return }

        let initialWidth = container.sidebarWidth
        let initialLocation = event.locationInWindow

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp { stop.pointee = true; return }
            container.sidebarWidth = initialWidth + event.locationInWindow.x - initialLocation.x
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
