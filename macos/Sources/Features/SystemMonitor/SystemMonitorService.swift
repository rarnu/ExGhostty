import Foundation
import Combine

/// 系统监控服务：负责检查 xtop 是否存在、启动/停止流式采集，并发布最新数据。
/// 标记为 `@unchecked Sendable` 是因为所有可变状态都在主线程/DispatchQueue.main 上串行访问。
final class SystemMonitorService: ObservableObject, @unchecked Sendable {
    /// 最新一次 xtop 输出。
    @Published private(set) var latestOutput: XTopOutput?
    /// 当前是否正在运行 xtop。
    @Published private(set) var isRunning = false
    /// 错误信息（例如 xtop 未安装、SSH 执行失败等）。
    @Published private(set) var errorMessage: String?

    private var process: Process?
    private var lineBuffer = Data()

    /// 正在采集的实例注册表（弱引用），用于程序退出时统一停止。
    /// 只在主线程访问。
    private static let runningInstances = NSHashTable<SystemMonitorService>.weakObjects()

    /// 停止所有正在采集的实例（供程序退出时调用，避免 xtop/ssh 流进程残留后台）。
    static func stopAll() {
        for service in runningInstances.allObjects {
            service.stop()
        }
    }

    /// 检查目标主机上是否存在 xtop 命令。
    static func checkXTopAvailable(connection: SSHConnection?) async -> Bool {
        if let connection {
            do {
                let path = try await SSHCommandExecutor.shared.execute(
                    remoteCommand: "command -v xtop || which xtop",
                    connection: connection
                )
                return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } catch {
                return false
            }
        } else {
            do {
                let path = try await ProcessRunner.run(shellCommand: "command -v xtop || which xtop")
                return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } catch {
                return false
            }
        }
    }

    /// 在指定主机上启动 xtop 流式采集。
    func start(connection: SSHConnection?) {
        guard !isRunning else { return }
        stop()
        lineBuffer.removeAll()

        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = nil
        }

        Task { [weak self] in
            guard let self else { return }
            let available = await Self.checkXTopAvailable(connection: connection)
            guard available else {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "xtop not detected".localized
                    self?.isRunning = false
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.isRunning = true
            }

            do {
                if let connection {
                    try await self.startRemote(connection: connection)
                } else {
                    try await self.startLocal()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.isRunning = false
                }
            }
        }
    }

    /// 停止 xtop 进程。
    func stop() {
        process?.terminate()
        process = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.runningInstances.remove(self)
            self.isRunning = false
        }
    }

    // MARK: - 本地执行

    private func startLocal() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", "xtop --all --json --stream 5"]
        try run(process: process)
    }

    // MARK: - 远程执行

    private func startRemote(connection: SSHConnection) async throws {
        let invocation = try await SSHCommandExecutor.shared.streamingInvocation(
            remoteCommand: "xtop --all --json --stream 5",
            connection: connection
        )

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        try run(process: process)
    }

    // MARK: - 通用流式读取

    private func run(process: Process) throws {
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        self.process = process

        let outHandle = outPipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.lineBuffer.append(data)
            self.flushLineBuffer()
        }

        process.terminationHandler = { [weak self] _ in
            outHandle.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Self.runningInstances.remove(self)
                self.isRunning = false
                self.process = nil
            }
        }

        try process.run()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.runningInstances.add(self)
        }
    }

    /// 从缓冲区中提取完整行并解析。
    private func flushLineBuffer() {
        while let range = lineBuffer.range(of: Data("\n".utf8)) {
            let lineData = lineBuffer.subdata(in: 0..<range.upperBound)
            lineBuffer.removeSubrange(0..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            processLine(line)
        }
    }

    /// 处理 xtop 输出的一行 JSON。
    private func processLine(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let data = text.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                if let date = Self.iso8601Formatter.date(from: string) {
                    return date
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
            }
            let output = try decoder.decode(XTopOutput.self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.latestOutput = output
            }
        } catch {
            // 记录解析失败，便于排查字段不匹配问题；忽略无法解析的行（例如 xtop 启动信息）。
            NSLog("[SystemMonitor] Failed to decode xtop line: \(error)")
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
