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
    var dividerFillColor: NSColor?
    
    override var isOpaque: Bool {
        false
    }
    
    /// 不绘制可见分隔线；系统仍保留 divider 热区用于拖拽。
    override func drawDivider(in rect: NSRect) {
        if let color = dividerFillColor {
            color.setFill()
            NSBezierPath.fill(rect)
        }
    }
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

    fileprivate let rightSidebarHostingView: NSHostingView<RightSidebarView>
    fileprivate let rightSidebarBackgroundView = SidebarBackgroundView()

    fileprivate let functionPanelHostingView: NSHostingView<FunctionPanelView>
    fileprivate let functionPanelBackgroundView = SidebarBackgroundView()

    private let functionTerminalSplitView = SidebarSplitView()
    private let rightSidebarSplitView = SidebarSplitView()

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

    private var _functionPanelWidth: CGFloat = 360
    var functionPanelWidth: CGFloat {
        get { _functionPanelWidth }
        set {
            _functionPanelWidth = max(360, min(newValue, 600))
            updateFunctionPanelWidth()
        }
    }

    private var functionPanelVisible: Bool = false {
        didSet {
            updateFunctionPanelWidth()
            rebuildRightSidebarView()
        }
    }

    private var selectedFunctionFeature: RightSidebarFeature? = nil {
        didSet {
            rebuildFunctionPanelView()
            rebuildRightSidebarView()
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
            onOpenConnection: nil,
            onAddGroup: nil,
            onSettings: nil
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

        // 右侧栏图标条（始终显示）
        let initialRightSidebar = RightSidebarView(
            selectedFeature: nil,
            terminalController: terminalController,
            onSelectFeature: nil
        )
        self.rightSidebarHostingView = NSHostingView(rootView: initialRightSidebar)
        self.rightSidebarHostingView.wantsLayer = true

        self.rightSidebarBackgroundView.backgroundColor = sidebarBackgroundColor

        // 功能面板（默认隐藏）
        let initialFunctionPanel = FunctionPanelView(feature: nil, terminalController: terminalController, onClose: nil)
        self.functionPanelHostingView = NSHostingView(rootView: initialFunctionPanel)
        self.functionPanelHostingView.wantsLayer = true

        self.functionPanelBackgroundView.backgroundColor = sidebarBackgroundColor

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

        [tabBarHostingView, terminalContentView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rightContainer.addSubview($0)
        }

        NSLayoutConstraint.activate([
            tabBarHostingView.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            tabBarHostingView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            tabBarHostingView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            tabBarHostingView.heightAnchor.constraint(equalToConstant: 28),

            terminalContentView.topAnchor.constraint(equalTo: tabBarHostingView.bottomAnchor),
            terminalContentView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            terminalContentView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),
            terminalContentView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
        ])

        // --- Right sidebar view ---
        rightSidebarBackgroundView.addSubview(rightSidebarHostingView)
        rightSidebarHostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rightSidebarHostingView.leadingAnchor.constraint(equalTo: rightSidebarBackgroundView.leadingAnchor),
            rightSidebarHostingView.topAnchor.constraint(equalTo: rightSidebarBackgroundView.topAnchor),
            rightSidebarHostingView.bottomAnchor.constraint(equalTo: rightSidebarBackgroundView.bottomAnchor),
            rightSidebarHostingView.trailingAnchor.constraint(equalTo: rightSidebarBackgroundView.trailingAnchor),
        ])

        // --- Function panel view ---
        functionPanelBackgroundView.addSubview(functionPanelHostingView)
        functionPanelHostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            functionPanelHostingView.leadingAnchor.constraint(equalTo: functionPanelBackgroundView.leadingAnchor),
            functionPanelHostingView.topAnchor.constraint(equalTo: functionPanelBackgroundView.topAnchor),
            functionPanelHostingView.bottomAnchor.constraint(equalTo: functionPanelBackgroundView.bottomAnchor),
            functionPanelHostingView.trailingAnchor.constraint(equalTo: functionPanelBackgroundView.trailingAnchor),
        ])

        // --- Function panel split view (terminal + function panel) ---
        functionTerminalSplitView.isVertical = true
        functionTerminalSplitView.dividerStyle = .thin
        functionTerminalSplitView.delegate = self
        functionTerminalSplitView.wantsLayer = true
        functionTerminalSplitView.layer?.backgroundColor = NSColor.clear.cgColor

        // --- Right sidebar split view ((terminal+function panel) + right sidebar strip) ---
        rightSidebarSplitView.isVertical = true
        rightSidebarSplitView.dividerStyle = .thin
        rightSidebarSplitView.delegate = self
        rightSidebarSplitView.wantsLayer = true
        rightSidebarSplitView.layer?.backgroundColor = NSColor.clear.cgColor

        // --- Split view ---
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        
        if let config = terminalController?.ghostty.config {
            let terminalBackgroundColor = NSColor(config.backgroundColor)
                .withAlphaComponent(config.backgroundOpacity)
            let sidebarColor = sidebarBackgroundColor(from: terminalBackgroundColor)
            splitView.dividerFillColor = sidebarColor
            rightSidebarSplitView.dividerFillColor = sidebarColor
            functionTerminalSplitView.dividerFillColor = sidebarColor
        }
        
        functionTerminalSplitView.addArrangedSubview(rightContainer)
        functionTerminalSplitView.addArrangedSubview(functionPanelBackgroundView)
        rightSidebarSplitView.addArrangedSubview(functionTerminalSplitView)
        rightSidebarSplitView.addArrangedSubview(rightSidebarBackgroundView)
        splitView.addArrangedSubview(sidebarBackgroundView)
        splitView.addArrangedSubview(rightSidebarSplitView)

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
        updateRightSidebarStripWidth()
        updateFunctionPanelWidth()
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
        // 同步 divider 颜色，使其与左侧栏/右侧栏/功能面板背景融为一体。
        let terminalBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)
        let sidebarColor = sidebarBackgroundColor(from: terminalBackgroundColor)
        splitView.dividerFillColor = sidebarColor
        splitView.setNeedsDisplay(splitView.bounds)
        rightSidebarSplitView.dividerFillColor = sidebarColor
        rightSidebarSplitView.setNeedsDisplay(rightSidebarSplitView.bounds)
        functionTerminalSplitView.dividerFillColor = sidebarColor
        functionTerminalSplitView.setNeedsDisplay(functionTerminalSplitView.bounds)
        
        rightSidebarBackgroundView.backgroundColor = sidebarColor
        functionPanelBackgroundView.backgroundColor = sidebarColor
        
        // splitView.layer?.backgroundColor = NSColor.clear.cgColor
        
        rebuildSidebarView()
        rebuildRightSidebarView()
        rebuildFunctionPanelView()
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
            onOpenConnection: { [weak tc] conn in
                guard let tc, let window = tc.window else { return }
                if conn.type == .telnet {
                    self.openTelnetConnection(conn, in: tc, from: window)
                } else {
                    self.openSSHConnection(conn, in: tc, from: window)
                }
            },
            onAddGroup: nil,
            onSettings: { [weak self, weak tc] in
                guard let self, let tc, let window = self.view.window else { return }
                SettingsWindowController.shared.show(relativeTo: window, config: tc.ghostty.config)
            }
        )
        sidebarHostingView.rootView = newSidebar
        sidebarBackgroundView.backgroundColor = sidebarBackgroundColor
    }

    // MARK: - 打开连接

    private func openTelnetConnection(_ conn: SSHConnection, in tc: TerminalController, from window: NSWindow) {
        guard let telnetPath = Self.resolveTelnetExecutable() else {
            let alert = NSAlert()
            alert.messageText = "Telnet not found".localized
            alert.informativeText = "The telnet command was not found on this Mac. Please install it (e.g. via Homebrew) and try again.".localized
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK".localized)
            alert.beginSheetModal(for: window)
            return
        }

        var cfg = Ghostty.SurfaceConfiguration()
        cfg.environmentVariables["TERM"] = "xterm-256color"
        let portArg = conn.port == 23 ? "" : " \(conn.port)"

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_telnet_\(conn.id.uuidString).exp")
        let user = conn.username.tclEscaped
        let pass = conn.password.tclEscaped
        let hasUser = !conn.username.isEmpty
        let hasPass = !conn.password.isEmpty

        let expectScript = """
        set timeout 10
        spawn \(telnetPath) \(conn.host)\(portArg)

        # 某些 Telnet 服务（如 Ubuntu 的 PAM）连接后会先出现一个假的 Password: 提示，
        # 直接回车即可跳过，随后才会出现真正的 login 提示。
        expect {
            -nocase "password:" { send "\\r" }
            timeout { }
            eof { exit }
        }

        \(hasUser ? """
        # 真正的用户名 / login 提示
        expect {
            -nocase "username:" { send "\(user)\\r" }
            -nocase "login:" { send "\(user)\\r" }
            -nocase "user:" { send "\(user)\\r" }
            timeout { }
            eof { exit }
        }
        sleep 0.1
        """ : "")

        # 真正的密码提示
        expect {
            -nocase "password:" {
                sleep 0.3
                \(hasPass ? "send \"\(pass)\\r\"" : "send \"\\r\"")
            }
            timeout { }
            eof { exit }
        }

        interact
        """

        do {
            try expectScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            cfg.command = "/usr/bin/expect \(scriptURL.path)"
        } catch {
            cfg.command = "\(telnetPath) \(conn.host)\(portArg)"
        }

        let ctrl = TerminalController.newTab(tc.ghostty, from: window, withBaseConfig: cfg)
        if let ctrl {
            ctrl.baseTitle = conn.name
            ctrl.titleOverride = conn.name
            ctrl.sshConnection = conn
            DispatchQueue.main.async {
                if let splitVC = ctrl.window?.contentViewController as? SidebarSplitViewController {
                    splitVC.rebuildTabBar()
                }
            }
        }
    }

    /// 查找本机可用的 telnet 可执行文件路径。
    private static func resolveTelnetExecutable() -> String? {
        let candidates = [
            "/usr/bin/telnet",
            "/opt/homebrew/bin/telnet",
            "/usr/local/bin/telnet"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // 常见路径都没有时，尝试让 shell 通过 PATH 查找。
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "command -v telnet"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if task.terminationStatus == 0,
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // ignore
        }
        return nil
    }

    private func openSSHConnection(_ conn: SSHConnection, in tc: TerminalController, from window: NSWindow) {
        var cfg = Ghostty.SurfaceConfiguration()

        // 把当前终端的真实行列数传给 expect，避免 expect 子进程读到的 stdin 尺寸错误。
        let gridSize = self.currentTerminalGridSize(for: tc) ?? (rows: 24, cols: 80)
        cfg.environmentVariables["GHOSTTY_ROWS"] = "\(gridSize.rows)"
        cfg.environmentVariables["GHOSTTY_COLS"] = "\(gridSize.cols)"
        cfg.environmentVariables["TERM"] = "xterm-256color"

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_\(conn.id.uuidString).exp")

        let expectScript: String
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_\(conn.id.uuidString).log")
        let logPath = logURL.path
        let reconnectPrompt = "Press any key to reconnect".localized.tclEscaped

        let syncPtyProc = """
        proc sync_ssh_pty {} {
            global spawn_out
            if {[catch {
                # 先尝试 expect 内置 stty 读当前 PTY 尺寸（iTerm2 等脚本的标准做法）。
                if {[catch {
                    set rows [stty rows]
                    set cols [stty columns]
                } tty_err]} {
                    set rows $env(GHOSTTY_ROWS)
                    set cols $env(GHOSTTY_COLS)
                    sshlog "fallback to env size: $rows $cols"
                }
                stty rows $rows columns $cols < $spawn_out(slave,name)
                sshlog "set ssh pty to $rows $cols"
            } err]} {
                sshlog "sync pty failed: $err"
            }
        }
        """

        if conn.authMode == .password, !conn.password.isEmpty {
            // 密码登录：用 expect 脚本自动输入密码，并在断开后支持按任意键重连。
            // 只隐藏 spawn 命令和密码提示本身的输出，登录成功后正常显示远程 shell。
            expectScript = """
            set timeout 15
            set password $env(SSHPASS)
            set logfile [open "\(logPath)" "a"]
            proc sshlog {msg} {
                global logfile
                puts $logfile "[clock format [clock seconds]] \\(msg)"
                flush $logfile
            }
            \(syncPtyProc)
            trap { sshlog "SIGTERM ignored" } SIGTERM
            trap { sshlog "SIGINT ignored" } SIGINT
            while {1} {
                sshlog "spawn ssh"
                log_user 0
                spawn /usr/bin/ssh \(conn.sshBaseArgs)
                sync_ssh_pty
                trap { sync_ssh_pty } SIGWINCH
                expect {
                    -nocase "password:" { send "$password\\r" }
                    timeout { sshlog "password timeout" }
                    eof { sshlog "ssh eof" }
                }
                log_user 1
                interact
                sshlog "interact returned"
                puts ""
                puts "\(reconnectPrompt)"
                expect_user -re . {}
                sshlog "reconnect key pressed"
            }
            """
            cfg.environmentVariables["SSHPASS"] = conn.password
        } else {
            // 密钥登录：同样用 expect 包装，实现断线后按任意键重连。
            // 只隐藏 spawn 命令本身的输出，其余 SSH 输出保持可见。
            expectScript = """
            set logfile [open "\(logPath)" "a"]
            proc sshlog {msg} {
                global logfile
                puts $logfile "[clock format [clock seconds]] \\(msg)"
                flush $logfile
            }
            \(syncPtyProc)
            trap { sshlog "SIGTERM ignored" } SIGTERM
            trap { sshlog "SIGINT ignored" } SIGINT
            while {1} {
                sshlog "spawn ssh"
                log_user 0
                spawn /usr/bin/ssh \(conn.sshBaseArgs)
                sync_ssh_pty
                trap { sync_ssh_pty } SIGWINCH
                log_user 1
                interact
                sshlog "interact returned"
                puts ""
                puts "\(reconnectPrompt)"
                expect_user -re . {}
                sshlog "reconnect key pressed"
            }
            """
        }

        do {
            try expectScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            cfg.command = "/usr/bin/expect \(scriptURL.path)"
        } catch {
            // 写入失败时回退到普通 ssh 命令
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
            ctrl.sshConnection = conn
            DispatchQueue.main.async {
                if let splitVC = ctrl.window?.contentViewController as? SidebarSplitViewController {
                    splitVC.rebuildTabBar()
                }
            }
        }
    }

    // MARK: - 右侧边栏

    func rebuildRightSidebarView() {
        guard let tc = terminalController else { return }
        let selected = self.selectedFunctionFeature
        let config = tc.ghostty.config

        let terminalBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)
        let sidebarBackgroundColor = sidebarBackgroundColor(from: terminalBackgroundColor)

        let newRightSidebar = RightSidebarView(
            selectedFeature: selected,
            terminalController: tc,
            onSelectFeature: { [weak self] feature in
                guard let self else { return }
                if self.functionPanelVisible && self.selectedFunctionFeature == feature {
                    self.functionPanelVisible = false
                    self.selectedFunctionFeature = nil
                } else {
                    self.selectedFunctionFeature = feature
                    self.functionPanelVisible = true
                }
            }
        )
        rightSidebarHostingView.rootView = newRightSidebar
        rightSidebarBackgroundView.backgroundColor = sidebarBackgroundColor
    }

    // MARK: - 功能面板

    func rebuildFunctionPanelView() {
        guard let tc = terminalController else { return }
        let feature = self.selectedFunctionFeature
        let config = tc.ghostty.config

        let terminalBackgroundColor = NSColor(config.backgroundColor)
            .withAlphaComponent(config.backgroundOpacity)
        let sidebarBackgroundColor = sidebarBackgroundColor(from: terminalBackgroundColor)

        let newFunctionPanel = FunctionPanelView(
            feature: feature,
            terminalController: tc,
            onClose: { [weak self] in
                self?.functionPanelVisible = false
                self?.selectedFunctionFeature = nil
            }
        )
        functionPanelHostingView.rootView = newFunctionPanel
        functionPanelBackgroundView.backgroundColor = sidebarBackgroundColor
    }

    // MARK: - 宽度控制

    private func updateSidebarWidth() {
        guard isViewLoaded else { return }
        let width = collapsed ? 32 : _sidebarWidth
        splitView.setPosition(width, ofDividerAt: 0)
    }

    private func updateRightSidebarStripWidth() {
        guard isViewLoaded else { return }
        let dividerThickness = rightSidebarSplitView.dividerThickness
        let position = max(0, rightSidebarSplitView.bounds.width - 32 - dividerThickness)
        rightSidebarSplitView.setPosition(position, ofDividerAt: 0)
    }

    private func updateFunctionPanelWidth() {
        guard isViewLoaded else { return }
        let width = functionPanelVisible ? _functionPanelWidth : 0
        let dividerThickness = functionTerminalSplitView.dividerThickness
        let position = max(0, functionTerminalSplitView.bounds.width - width - dividerThickness)
        functionTerminalSplitView.setPosition(position, ofDividerAt: 0)
    }

    /// 根据当前聚焦的终端 surface 计算行/列数，用于 expect 脚本初始化 SSH PTY 尺寸。
    private func currentTerminalGridSize(for controller: TerminalController?) -> (rows: Int, cols: Int)? {
        guard let surface = controller?.focusedSurface else { return nil }
        let size = surface.bounds.size
        let cellSize = surface.cellSize
        guard cellSize.width > 0, cellSize.height > 0, size.width > 0, size.height > 0 else { return nil }
        let cols = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        return (rows, cols)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if splitView === rightSidebarSplitView {
            // 右側图标条固定 32，不可拖拽
            let maxPos = splitView.bounds.width - splitView.dividerThickness
            return maxPos - 32
        }
        if splitView === functionTerminalSplitView {
            let maxPos = splitView.bounds.width - splitView.dividerThickness
            return functionPanelVisible ? maxPos - 600 : maxPos
        }
        return collapsed ? 32 : 150
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if splitView === rightSidebarSplitView {
            let maxPos = splitView.bounds.width - splitView.dividerThickness
            return maxPos - 32
        }
        if splitView === functionTerminalSplitView {
            let maxPos = splitView.bounds.width - splitView.dividerThickness
            return functionPanelVisible ? maxPos - 360 : maxPos
        }
        return collapsed ? 32 : min(400, splitView.bounds.width - splitView.dividerThickness)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if splitView === rightSidebarSplitView {
            let maxPos = splitView.bounds.width - splitView.dividerThickness
            return maxPos - 32
        }
        if splitView === functionTerminalSplitView {
            let maxPos = splitView.bounds.width - splitView.dividerThickness
            let minPos: CGFloat = functionPanelVisible ? maxPos - 600 : maxPos
            let maxAllowed: CGFloat = functionPanelVisible ? maxPos - 360 : maxPos
            return max(minPos, min(proposedPosition, maxAllowed))
        }
        let minPos: CGFloat = collapsed ? 32 : 150
        let maxPos = min(400, splitView.bounds.width - splitView.dividerThickness)
        return max(minPos, min(proposedPosition, maxPos))
    }

    /// 窗口整体 resize 时保持固定宽度区域不变，只调整可伸缩区域。
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let newBounds = splitView.bounds
        let dividerThickness = splitView.dividerThickness

        if splitView === rightSidebarSplitView {
            // 保持右侧图标条 32 不变
            let rightWidth: CGFloat = 32
            let leftWidth = max(0, newBounds.width - rightWidth - dividerThickness)
            splitView.subviews[0].frame = NSRect(
                x: 0, y: 0,
                width: leftWidth,
                height: newBounds.height
            )
            splitView.subviews[1].frame = NSRect(
                x: leftWidth + dividerThickness, y: 0,
                width: rightWidth,
                height: newBounds.height
            )
            return
        }

        if splitView === functionTerminalSplitView {
            let rightWidth = functionPanelVisible ? _functionPanelWidth : 0
            let leftWidth = max(0, newBounds.width - rightWidth - dividerThickness)
            splitView.subviews[0].frame = NSRect(
                x: 0, y: 0,
                width: leftWidth,
                height: newBounds.height
            )
            splitView.subviews[1].frame = NSRect(
                x: leftWidth + dividerThickness, y: 0,
                width: rightWidth,
                height: newBounds.height
            )
            return
        }

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

    /// 用户拖动 divider 时同步更新记录的面板宽度。
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let resizedSplitView = notification.object as? NSSplitView else { return }

        if resizedSplitView === functionTerminalSplitView {
            guard functionPanelVisible else { return }
            let newWidth = resizedSplitView.subviews[1].frame.width
            if newWidth >= 360 && newWidth <= 600 {
                _functionPanelWidth = newWidth
            }
            return
        }

        guard !collapsed else { return }
        let newWidth = resizedSplitView.subviews[0].frame.width
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

// MARK: - 端口转发 Tab 窗口

/// 端口转发管理页窗口控制器，作为 Tab 加入当前 TerminalWindow 的标签组。
