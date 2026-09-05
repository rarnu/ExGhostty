import AppKit
import SwiftUI
import GhosttyKit

// MARK: - 日志实时流

/// 容器日志实时流：本地直接启动 `docker logs -f` 进程；SSH 通过 SSHCommandExecutor 的流式调用在远程执行。
/// 标记为 `@unchecked Sendable` 是因为所有可变状态都在主线程上串行访问
///（readabilityHandler 的数据先进入缓冲区，统一合并到主线程 flush）。
final class DockerLogsService: ObservableObject, @unchecked Sendable {
    @Published private(set) var logs: String = ""

    private var process: Process?
    private var buffer = Data()
    private var flushScheduled = false

    /// 日志内容上限，超出后丢弃最旧的部分，避免长时间 follow 占用过多内存。
    private static let maxLogLength = 300_000

    /// 正在流式读取的实例注册表（弱引用），用于程序退出时统一停止。
    /// 只在主线程访问。
    private static let runningInstances = NSHashTable<DockerLogsService>.weakObjects()

    /// 停止所有正在流式读取的实例（供程序退出时调用，避免 docker logs -f/ssh 进程残留后台）。
    static func stopAll() {
        for service in runningInstances.allObjects {
            service.stop()
        }
    }

    func start(connection: SSHConnection?, containerID: String) {
        stop()
        let command = "docker logs -f --tail 200 '\(containerID)' 2>&1"
        Task { [weak self] in
            guard let self else { return }
            do {
                let process = Process()
                if let connection {
                    let invocation = try await SSHCommandExecutor.shared.streamingInvocation(
                        remoteCommand: command,
                        connection: connection
                    )
                    process.executableURL = invocation.executableURL
                    process.arguments = invocation.arguments
                    process.environment = invocation.environment
                } else {
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-l", "-c", command]
                }
                try run(process)
            } catch {
                append(text: "[\(error.localizedDescription)]\n")
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.runningInstances.remove(self)
        }
    }

    // MARK: - 内部辅助

    private func run(_ process: Process) throws {
        let outPipe = Pipe()
        process.standardOutput = outPipe
        // docker 的日志已通过 2>&1 合并进 stdout；进程自身的 stderr（如 ssh 报错）丢弃。
        process.standardError = FileHandle.nullDevice
        self.process = process

        let outHandle = outPipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            scheduleFlush()
        }

        process.terminationHandler = { [weak self] _ in
            outHandle.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                flushBuffer()
                Self.runningInstances.remove(self)
                self.process = nil
            }
        }

        try process.run()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.runningInstances.add(self)
        }
    }

    /// 合并短时间内频繁的读取事件，避免每条日志都触发一次 UI 刷新。
    private func scheduleFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                flushScheduled = false
                flushBuffer()
            }
        }
    }

    /// 必须在主线程调用。
    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        logs += text
        if logs.count > Self.maxLogLength {
            logs = String(logs.suffix(Self.maxLogLength * 2 / 3))
        }
    }

    private func append(text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            logs += text
        }
    }
}

// MARK: - 日志窗口

/// 容器日志窗口管理器：按容器去重，重复打开时仅把已有窗口置前。
enum DockerLogsWindowManager {
    private static var controllers: [String: DockerLogsWindowController] = [:]

    static func show(
        connection: SSHConnection?,
        container: DockerContainer,
        config: Ghostty.Config?,
        parentWindow: NSWindow?
    ) {
        let key = "\(connection?.id.uuidString ?? "local"):\(container.id)"
        if let existing = controllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = DockerLogsWindowController(
            connection: connection,
            container: container,
            config: config,
            parentWindow: parentWindow,
            onWindowClosed: {
                controllers[key] = nil
            }
        )
        controllers[key] = controller
        controller.showWindow(nil)
    }
}

/// 容器日志独立窗口控制器：非模态、永远在最前，关闭时停止日志流。
final class DockerLogsWindowController: NSWindowController, NSWindowDelegate {
    private let service = DockerLogsService()
    private var onWindowClosed: (() -> Void)?
    private var escapeEventMonitor: Any?

    init(
        connection: SSHConnection?,
        container: DockerContainer,
        config: Ghostty.Config?,
        parentWindow: NSWindow? = nil,
        onWindowClosed: (() -> Void)? = nil
    ) {
        self.onWindowClosed = onWindowClosed

        let window = DockerLogsWindow(config: config)
        super.init(window: window)
        window.delegate = self

        let contentView = DockerLogsView(service: service)
            .frame(minWidth: 640, minHeight: 400)
            // 保持根视图背景透明，让窗口级背景/模糊效果透出来。
            .background(Color.clear)

        let hostingView = NSHostingView(rootView: ThemedRoot { contentView })
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        window.contentView = containerView
        window.title = L("Logs: %@", container.names)
        window.centerRelative(to: parentWindow)

        // 配置与主窗口一致的背景模糊。
        window.configureBackgroundBlur(config: config, container: containerView)

        // 监听 ESC 键，确保即使文本持有焦点也能关闭窗口。
        setupEscapeMonitor()

        service.start(connection: connection, containerID: container.id)
    }

    deinit {
        if let monitor = escapeEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupEscapeMonitor() {
        escapeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 是 ESC 的虚拟键码。
            guard event.keyCode == 53 else { return event }
            self?.window?.close()
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        service.stop()
        onWindowClosed?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// 日志窗口：永远在最前，但非模态。
private final class DockerLogsWindow: GhosttyPanelWindow {
    init(config: Ghostty.Config?) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            config: config
        )

        self.minSize = NSSize(width: 640, height: 400)

        // 永远在最前，但不阻塞父窗口。
        self.level = .floating
        self.collectionBehavior = [.moveToActiveSpace, .transient]
    }
}

// MARK: - 日志内容视图

private struct DockerLogsView: View {
    @ObservedObject var service: DockerLogsService

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(service.logs.isEmpty ? "No output".localized : service.logs)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    // 底部锚点，新日志到达时自动滚动到底。
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
            }
            .onChange(of: service.logs) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
