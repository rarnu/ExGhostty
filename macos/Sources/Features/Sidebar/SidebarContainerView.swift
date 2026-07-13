import AppKit
import SwiftUI
import Combine

/// 带左侧栏和右侧标签栏的终端视图容器
/// 布局:
/// ┌──────────┬────────────────────────────┐
/// │ sidebar  │ [Tab Bar: Tabs | +]        │
/// │          ├────────────────────────────┤
/// │          │    Terminal Content         │
/// └──────────┴────────────────────────────┘
class SidebarTerminalTerminalViewContainer: TerminalViewContainer {
    // MARK: - 子视图

    /// 侧边栏的 NSHostingView
    private let sidebarHostingView: NSHostingView<SidebarView>

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
            sidebarWidthConstraint?.constant = newValue ? 0 : _sidebarWidth
            sidebarHostingView.isHidden = newValue
            dividerView.isHidden = newValue
            rebuildSidebarView()
            needsLayout = true
        }
    }

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

        let initialSidebar = SidebarView(
            collapsed: false,
            onToggleCollapse: nil,
            onNewLocalTerminal: nil,
            onNewPortForward: nil,
            onOpenSSH: nil
        )
        self.sidebarHostingView = NSHostingView(rootView: initialSidebar)

        let initialTabBar = TabBarView(
            windows: [],
            selectedWindow: nil,
            onSelectTab: nil,
            onNewTab: nil,
            onCloseTab: nil
        )
        self.tabBarHostingView = NSHostingView(rootView: initialTabBar)

        super.init(rootView: rootView)

        setupViews()
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

    // MARK: - 视图设置

    private func setupViews() {
        terminalContentView = subviews.first
        if let tv = terminalContentView {
            tv.removeFromSuperview()
        }

        // 构建层级: self → [sidebar, divider, rightContainer]
        // rightContainer → [tabBar, tabDivider, terminal]
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

        // 在 setupConstraints 之后更新 observer（window 可能还没设置）
        DispatchQueue.main.async { [weak self] in
            self?.setupObservers()
            self?.rebuildSidebarView()
            self?.rebuildTabBar()
        }
    }

    private func setupConstraints() {
        guard let tv = terminalContentView else { return }

        let swc = sidebarHostingView.widthAnchor.constraint(equalToConstant: _sidebarWidth)
        swc.priority = .defaultHigh
        self.sidebarWidthConstraint = swc

        let tabBarHeight: CGFloat = 28

        NSLayoutConstraint.activate([
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
            windows: windows,
            selectedWindow: selected,
            onSelectTab: { target in
                target.makeKeyAndOrderFront(nil)
                if let tg = window.tabGroup { tg.selectedWindow = target }
            },
            onNewTab: { [weak self] in
                guard let self, let tc = self.terminalController,
                      let surface = tc.focusedSurface?.surface else { return }
                tc.ghostty.newTab(surface: surface)
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

        let newSidebar = SidebarView(
            collapsed: collapsed,
            onToggleCollapse: { [weak self] in
                self?.collapsed.toggle()
            },
            onNewLocalTerminal: { [weak tc] in
                guard let tc, let window = tc.window else { return }
                // 在当前窗口中创建新标签
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
                // 在当前窗口中创建新标签
                _ = TerminalController.newTab(tc.ghostty, from: window, withBaseConfig: config)
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
