import AppKit
import SwiftUI
import Combine

/// 将给定颜色调暗一点，用作左侧栏背景，使其比右侧终端区域稍深。
private func sidebarBackgroundColor(from color: NSColor) -> NSColor {
    color.shadow(withLevel: 0.08) ?? color
}

// MARK: - Split View

/// 自定义 NSSplitView，隐藏可见分隔线但保留拖拽热区。
class SidebarSplitView: NSSplitView {
    /// 不绘制可见分隔线；系统仍保留 divider 热区用于拖拽。
    override func drawDivider(in rect: NSRect) { }
}

// MARK: - Split View Controller

/// 用原生 NSSplitView 实现的侧边栏 + 终端分栏布局。
/// 分隔条由系统管理，不会出现自定义 layer resize 时的白色竖线问题。
class SidebarSplitViewController: NSViewController, NSSplitViewDelegate {

    // MARK: - 子视图

    fileprivate let sidebarHostingView: NSHostingView<SidebarView>
    fileprivate let sidebarBackgroundView = SidebarBackgroundView()
    fileprivate let tabBarHostingView: NSHostingView<TabBarView>
    fileprivate let terminalContentView: TerminalViewContainer

    private let tabDividerView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }()

    private let splitView = SidebarSplitView()

    private var tabGroupObserver: NSKeyValueObservation?
    private var tabWindowsObserver: NSKeyValueObservation?
    private var windowTitleNotif: NSObjectProtocol?
    private var windowDidBecomeKeyNotif: NSObjectProtocol?
    private var configCancellable: Any?
    private var tabBarViewID: Int = 0

    private var _sidebarWidth: CGFloat = 250
    var sidebarWidth: CGFloat {
        get { _sidebarWidth }
        set {
            _sidebarWidth = max(150, min(newValue, 500))
            updateSidebarWidth()
        }
    }

    private var _collapsed: Bool = false
    var collapsed: Bool {
        get { _collapsed }
        set {
            guard _collapsed != newValue else { return }
            _collapsed = newValue
            updateSidebarWidth()
            rebuildSidebarView()
        }
    }

    weak var terminalController: TerminalController?

    /// 透传给内部 TerminalViewContainer 的初始内容尺寸，用于窗口默认大小恢复。
    var initialContentSize: NSSize? {
        get { terminalContentView.initialContentSize }
        set { terminalContentView.initialContentSize = newValue }
    }

    // MARK: - 初始化

    init<Root: View>(
        terminalController: TerminalController,
        @ViewBuilder rootView: () -> Root
    ) {
        self.terminalController = terminalController

        let config = terminalController.ghostty.config
        let terminalBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)
        let sidebarBackgroundColor = sidebarBackgroundColor(from: terminalBackgroundColor)

        let initialSidebar = SidebarView(
            collapsed: false,
            backgroundColor: sidebarBackgroundColor,
            onToggleCollapse: nil,
            onNewLocalTerminal: nil,
            onNewPortForward: nil,
            onOpenSSH: nil
        )
        self.sidebarHostingView = NSHostingView(rootView: initialSidebar)
        self.sidebarHostingView.wantsLayer = true

        self.sidebarBackgroundView.backgroundColor = sidebarBackgroundColor

        let initialTabBar = TabBarView(
            viewID: 0,
            windows: [],
            selectedWindow: nil,
            backgroundColor: terminalBackgroundColor,
            onSelectTab: nil,
            onCloseTab: nil
        )
        self.tabBarHostingView = NSHostingView(rootView: initialTabBar)
        self.tabBarHostingView.wantsLayer = true
        self.tabBarHostingView.layer?.backgroundColor = terminalBackgroundColor.cgColor

        // terminalContentView 使用 TerminalViewContainer 包裹 SwiftUI root view，
        // 保留玻璃效果、初始内容尺寸等原有行为。
        self.terminalContentView = TerminalViewContainer(rootView: rootView)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        tabGroupObserver?.invalidate()
        tabWindowsObserver?.invalidate()
        if let obs = windowTitleNotif { NotificationCenter.default.removeObserver(obs) }
        if let obs = windowDidBecomeKeyNotif { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - 视图生命周期

    override func loadView() {
        // --- Sidebar view ---
        sidebarBackgroundView.addSubview(sidebarHostingView)
        sidebarHostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarHostingView.leadingAnchor.constraint(equalTo: sidebarBackgroundView.leadingAnchor),
            sidebarHostingView.topAnchor.constraint(equalTo: sidebarBackgroundView.topAnchor),
            sidebarHostingView.bottomAnchor.constraint(equalTo: sidebarBackgroundView.bottomAnchor),
            sidebarHostingView.trailingAnchor.constraint(equalTo: sidebarBackgroundView.trailingAnchor),
        ])

        // --- Terminal view ---
        let rightContainer = NSView()

        [tabBarHostingView, tabDividerView, terminalContentView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rightContainer.addSubview($0)
        }

        NSLayoutConstraint.activate([
            tabBarHostingView.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            tabBarHostingView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            tabBarHostingView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            tabBarHostingView.heightAnchor.constraint(equalToConstant: 28),

            tabDividerView.topAnchor.constraint(equalTo: tabBarHostingView.bottomAnchor),
            tabDividerView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            tabDividerView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            tabDividerView.heightAnchor.constraint(equalToConstant: 1),

            terminalContentView.topAnchor.constraint(equalTo: tabDividerView.bottomAnchor),
            terminalContentView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            terminalContentView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
            terminalContentView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
        ])

        // --- Split view ---
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.wantsLayer = true
        if let config = terminalController?.ghostty.config {
            let terminalBackgroundColor = NSColor(config.backgroundColor)
                .withAlphaComponent(config.backgroundOpacity)
            splitView.layer?.backgroundColor = terminalBackgroundColor.cgColor
        }
        splitView.addArrangedSubview(sidebarBackgroundView)
        splitView.addArrangedSubview(rightContainer)

        self.view = splitView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupConfigObserver()

        DispatchQueue.main.async { [weak self] in
            self?.setupObservers()
            self?.rebuildSidebarView()
            self?.rebuildTabBar()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // view 已进入窗口层级且即将显示，此时 setPosition 能拿到有效 bounds。
        updateSidebarWidth()
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
        if let window = self.view.window as? TerminalWindow {
            let dc = Ghostty.SurfaceView.DerivedConfig(config)
            window.syncAppearance(dc)
        }
        // 同步 split view 背景色，确保 divider 间隙与右侧终端背景融为一体。
        let terminalBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)
        splitView.layer?.backgroundColor = terminalBackgroundColor.cgColor
        rebuildSidebarView()
        rebuildTabBar()
    }

    // MARK: - 观察者

    private func setupObservers() {
        guard let window = self.view.window else { return }

        tabGroupObserver = window.observe(\.tabGroup, options: [.initial, .new]) { [weak self] (win, _) in
            guard let self else { return }
            if let tg = win.tabGroup {
                let weakSelf = self
                self.tabWindowsObserver = tg.observe(\.windows, options: [.initial, .new]) { (_, _) in
                    DispatchQueue.main.async {
                        weakSelf.rebuildTabBar()
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
        guard let window = self.view.window else { return }
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

        let terminalBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)

        let newBar = TabBarView(
            viewID: tabBarViewID,
            windows: windows,
            selectedWindow: selected,
            backgroundColor: terminalBackgroundColor,
            onSelectTab: { target in
                target.makeKeyAndOrderFront(nil)
                if let tg = window.tabGroup { tg.selectedWindow = target }
            },
            onCloseTab: { target in target.close() }
        )
        tabBarHostingView.rootView = newBar
        tabBarHostingView.layer?.backgroundColor = terminalBackgroundColor.cgColor
    }

    // MARK: - 侧边栏

    func rebuildSidebarView() {
        guard let tc = terminalController else { return }
        let collapsed = self._collapsed
        let config = tc.ghostty.config

        let terminalBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)
        let sidebarBackgroundColor = sidebarBackgroundColor(from: terminalBackgroundColor)

        let newSidebar = SidebarView(
            collapsed: collapsed,
            backgroundColor: sidebarBackgroundColor,
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
                        if let splitVC = ctrl.window?.contentViewController as? SidebarSplitViewController {
                            splitVC.rebuildTabBar()
                        }
                    }
                }
            }
        )
        sidebarHostingView.rootView = newSidebar
        sidebarBackgroundView.backgroundColor = sidebarBackgroundColor
    }

    // MARK: - 宽度控制

    private func updateSidebarWidth() {
        guard isViewLoaded else { return }
        let width = collapsed ? 32 : _sidebarWidth
        splitView.setPosition(width, ofDividerAt: 0)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        collapsed ? 32 : 150
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(400, splitView.bounds.width - splitView.dividerThickness)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofDividerAt dividerIndex: Int
    ) -> CGFloat {
        let minPos: CGFloat = collapsed ? 32 : 150
        let maxPos = min(400, splitView.bounds.width - splitView.dividerThickness)
        return max(minPos, min(proposedPosition, maxPos))
    }

    /// 窗口整体 resize 时保持侧边栏宽度不变，只调整右侧终端区域。
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let newBounds = splitView.bounds
        let dividerThickness = splitView.dividerThickness
        let sidebarWidth = collapsed ? 32 : _sidebarWidth
        let detailWidth = max(0, newBounds.width - sidebarWidth - dividerThickness)

        splitView.subviews[0].frame = NSRect(
            x: 0, y: 0,
            width: sidebarWidth,
            height: newBounds.height
        )
        splitView.subviews[1].frame = NSRect(
            x: sidebarWidth + dividerThickness, y: 0,
            width: detailWidth,
            height: newBounds.height
        )
    }

    /// 用户拖动 divider 时同步更新记录的侧边栏宽度。
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !collapsed else { return }
        let newWidth = splitView.subviews[0].frame.width
        if newWidth >= 150 && newWidth <= 500 {
            _sidebarWidth = newWidth
        }
    }

    // MARK: - 终端内容视图

    /// 返回终端内容视图，供 TerminalController 使用
    var terminalView: NSView? { terminalContentView }
}

// MARK: - 扩展

extension BaseTerminalController {
    var sidebarSplitViewController: SidebarSplitViewController? {
        window?.contentViewController as? SidebarSplitViewController
    }
}

// MARK: - 背景视图

/// 负责绘制侧边栏背景色的 layer-backed NSView。
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
