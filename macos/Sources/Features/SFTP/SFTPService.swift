import Foundation
import Combine

/// SFTP/SSH 相关错误。
enum SFTPError: Error, LocalizedError {
    case invalidConnection
    case commandNotFound(String)
    case listingFailed(String)
    case transferFailed(String)
    case helperSetupFailed
    case unsupportedAuth

    var errorDescription: String? {
        switch self {
        case .invalidConnection: return "无效的 SSH 连接"
        case .commandNotFound(let cmd): return "找不到命令: \(cmd)"
        case .listingFailed(let msg): return "目录列表失败: \(msg)"
        case .transferFailed(let msg): return "传输失败: \(msg)"
        case .helperSetupFailed: return "密码助手脚本创建失败"
        case .unsupportedAuth: return "不支持的认证方式"
        }
    }
}

/// 负责执行远程命令和 rsync 传输。
actor SFTPService {
    static let shared = SFTPService()
    private init() {}

    // MARK: - 目录列表

    /// 列出远程目录内容。优先使用 `find -printf`；失败时回退到 `ls -la`。
    func listDirectory(
        connection: SSHConnection,
        path: String,
        showHidden: Bool
    ) async throws -> [SFTPFileItem] {
        let escapedPath = shellEscape(path)
        // find 输出格式: <类型>\t<大小>\t<名称>\t<权限八进制>\t<修改时间epoch>
        let findCmd = "cd \(escapedPath) && find . -maxdepth 1 -mindepth 1 -printf '%y\\t%s\\t%f\\t%m\\t%T@\\n'"
        let output: String
        do {
            output = try await runSSHCommand(connection: connection, remoteCommand: findCmd)
        } catch {
            // 回退到 ls -la
            let lsCmd = "ls -la \(escapedPath)"
            let lsOutput = try await runSSHCommand(connection: connection, remoteCommand: lsCmd)
            return try parseLSOutput(lsOutput, showHidden: showHidden)
        }

        let items = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> SFTPFileItem? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 5 else { return nil }
                let typeChar = String(parts[0])
                let size = Int64(parts[1])
                let name = String(parts[2])
                let perms = String(parts[3])
                let mtime = TimeInterval(parts[4])

                if name == "." || name == ".." { return nil }
                if !showHidden && name.hasPrefix(".") { return nil }

                let type: SFTPItemType
                switch typeChar {
                case "d": type = .directory
                case "l": type = .symlink
                case "f", "-": type = .file
                default: type = .other
                }

                return SFTPFileItem(
                    name: name,
                    type: type,
                    size: size,
                    modificationDate: mtime.map { Date(timeIntervalSince1970: $0) },
                    permissions: perms
                )
            }
        return items
    }

    /// 刷新当前目录：返回当前工作目录路径。
    func currentRemoteDirectory(connection: SSHConnection) async throws -> String {
        let output = try await runSSHCommand(connection: connection, remoteCommand: "pwd")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 上传

    func uploadFile(
        connection: SSHConnection,
        localURL: URL,
        remoteDirectory: String,
        task: SFTPTask
    ) async throws {
        let remotePath = remoteDirectory + "/" + localURL.lastPathComponent
        try await runRsyncUpload(
            connection: connection,
            localPath: localURL.path,
            remotePath: remotePath,
            task: task
        )
    }

    func uploadDirectory(
        connection: SSHConnection,
        localURL: URL,
        remoteDirectory: String,
        task: SFTPTask
    ) async throws {
        let archiveName = "ghostty_upload_\(UUID().uuidString).tar.gz"
        let localArchive = FileManager.default.temporaryDirectory.appendingPathComponent(archiveName)
        let remoteArchive = remoteDirectory + "/" + archiveName

        defer { try? FileManager.default.removeItem(at: localArchive) }

        await updateTask(task, progress: 0.05, state: .running)

        // 1. 本地压缩
        try await createTarArchive(source: localURL, archive: localArchive)
        await updateTask(task, progress: 0.15)

        // 2. 上传压缩包
        try await runRsyncUpload(
            connection: connection,
            localPath: localArchive.path,
            remotePath: remoteArchive,
            task: task,
            progressOffset: 0.15,
            progressScale: 0.70,
            compress: true
        )

        // 3. 远程解压
        await updateTask(task, progress: 0.88)
        let extractCmd = "cd \(shellEscape(remoteDirectory)) && tar -xzf \(shellEscape(archiveName)) && rm \(shellEscape(archiveName))"
        _ = try await runSSHCommand(connection: connection, remoteCommand: extractCmd)

        await updateTask(task, progress: 1.0, state: .completed)
    }

    // MARK: - 下载

    func downloadFile(
        connection: SSHConnection,
        remotePath: String,
        localDirectory: URL,
        task: SFTPTask
    ) async throws {
        let localURL = localDirectory.appendingPathComponent((remotePath as NSString).lastPathComponent)
        try await runRsyncDownload(
            connection: connection,
            remotePath: remotePath,
            localPath: localURL.path,
            task: task
        )
    }

    func downloadDirectory(
        connection: SSHConnection,
        remotePath: String,
        localDirectory: URL,
        task: SFTPTask
    ) async throws {
        let name = (remotePath as NSString).lastPathComponent
        let archiveName = "\(name).tar.gz"
        let remoteArchive = (remotePath as NSString).deletingLastPathComponent + "/" + archiveName
        let localArchive = localDirectory.appendingPathComponent(archiveName)

        defer {
            try? FileManager.default.removeItem(at: localArchive)
            let cleanupCmd = "rm -f \(shellEscape(remoteArchive))"
            // 尽量清理，不抛错
            Task {
                _ = try? await runSSHCommand(connection: connection, remoteCommand: cleanupCmd)
            }
        }

        await updateTask(task, progress: 0.05, state: .running)

        // 1. 远程压缩
        let parent = shellEscape((remotePath as NSString).deletingLastPathComponent)
        let base = shellEscape(name)
        let compressCmd = "cd \(parent) && tar -czf \(shellEscape(archiveName)) \(base)"
        _ = try await runSSHCommand(connection: connection, remoteCommand: compressCmd)
        await updateTask(task, progress: 0.25)

        // 2. 下载压缩包
        try await runRsyncDownload(
            connection: connection,
            remotePath: remoteArchive,
            localPath: localArchive.path,
            task: task,
            progressOffset: 0.25,
            progressScale: 0.65,
            compress: true
        )

        // 3. 本地解压
        await updateTask(task, progress: 0.93)
        try await extractTarArchive(archive: localArchive, destination: localDirectory)
        await updateTask(task, progress: 1.0, state: .completed)
    }

    // MARK: - 删除

    func deleteFile(
        connection: SSHConnection,
        remotePath: String
    ) async throws {
        let cmd = "rm -f \(shellEscape(remotePath))"
        _ = try await runSSHCommand(connection: connection, remoteCommand: cmd)
    }

    func deleteDirectory(
        connection: SSHConnection,
        remotePath: String
    ) async throws {
        let cmd = "rm -rf \(shellEscape(remotePath))"
        _ = try await runSSHCommand(connection: connection, remoteCommand: cmd)
    }

    // MARK: - 重命名

    func rename(
        connection: SSHConnection,
        from oldPath: String,
        to newPath: String
    ) async throws {
        let cmd = "mv \(shellEscape(oldPath)) \(shellEscape(newPath))"
        _ = try await runSSHCommand(connection: connection, remoteCommand: cmd)
    }

    // MARK: - 内部辅助

    private func backend(for connection: SSHConnection) throws -> SFTPBackend {
        switch connection.authMode {
        case .key: return KeySFTPBackend(connection: connection)
        case .password: return PasswordSFTPBackend(connection: connection)
        }
    }

    /// 执行任意远程命令并返回标准输出。
    func executeCommand(
        connection: SSHConnection,
        remoteCommand: String
    ) async throws -> String {
        return try await runSSHCommand(connection: connection, remoteCommand: remoteCommand)
    }

    private func runSSHCommand(
        connection: SSHConnection,
        remoteCommand: String
    ) async throws -> String {
        let backend = try backend(for: connection)
        return try await backend.execute(remoteCommand: remoteCommand)
    }

    // MARK: - rsync 传输

    private func runRsyncUpload(
        connection: SSHConnection,
        localPath: String,
        remotePath: String,
        task: SFTPTask,
        progressOffset: Double = 0,
        progressScale: Double = 1,
        compress: Bool = false
    ) async throws {
        let backend = try backend(for: connection)
        try await backend.withRsyncChannel { socket in
            var args = ["--partial", "--progress", "-e", "ssh -S \(socket)"]
            if compress { args.append("-z") }
            args.append(localPath)
            args.append("\(connection.host):\(remotePath)")
            try await runRsync(args: args, environment: [:], task: task, progressOffset: progressOffset, progressScale: progressScale)
        }
    }

    private func runRsyncDownload(
        connection: SSHConnection,
        remotePath: String,
        localPath: String,
        task: SFTPTask,
        progressOffset: Double = 0,
        progressScale: Double = 1,
        compress: Bool = false
    ) async throws {
        let backend = try backend(for: connection)
        try await backend.withRsyncChannel { socket in
            var args = ["--partial", "--progress", "-e", "ssh -S \(socket)"]
            if compress { args.append("-z") }
            args.append("\(connection.host):\(remotePath)")
            args.append(localPath)
            try await runRsync(args: args, environment: [:], task: task, progressOffset: progressOffset, progressScale: progressScale)
        }
    }

    private func runRsync(
        args: [String],
        environment: [String: String],
        task: SFTPTask,
        progressOffset: Double,
        progressScale: Double
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        await MainActor.run { task.process = process }

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            let outHandle = outPipe.fileHandleForReading
            outHandle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
                while let range = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer.subdata(in: 0..<range.upperBound)
                    buffer.removeSubrange(0..<range.upperBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    if let percent = Self.parseRsyncProgress(line) {
                        let overall = progressOffset + percent * progressScale
                        DispatchQueue.main.async {
                            task.progress = min(overall, 0.99)
                        }
                    }
                }
            }

            process.terminationHandler = { _ in
                outHandle.readabilityHandler = nil
                DispatchQueue.main.async { task.process = nil }
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let cmd = (["rsync"] + args).joined(separator: " ")
                    let msg = stderr.isEmpty ? "rsync 退出码 \(process.terminationStatus)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: SFTPError.transferFailed("[\(cmd)] \(msg)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - 压缩/解压

    private func createTarArchive(source: URL, archive: URL) async throws {
        let parent = source.deletingLastPathComponent().path
        let name = source.lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-czf", archive.path,
            "--exclude=.DS_Store",
            "--exclude=._*",
            "--exclude=.Spotlight-V100",
            "--exclude=.Trashes",
            "--exclude=.fseventsd",
            "--exclude=.TemporaryItems",
            "-C", parent, name
        ]
        try await runLocalProcess(process)
    }

    private func extractTarArchive(archive: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        try await runLocalProcess(process)
    }

    private func runLocalProcess(_ process: Process) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SFTPError.transferFailed("本地进程退出码 \(process.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Backend 共享工具

    fileprivate struct SSHCommandInvocation {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }

    /// 运行一次 SSH 命令调用，返回标准输出；失败时抛出包含标准错误的 SFTPError。
    fileprivate static func runCommand(_ invocation: SSHCommandInvocation) async throws -> String {
        let (stdout, stderr, status) = try await run(invocation: invocation, captureOutput: true)
        if status == 0 {
            return stdout
        } else {
            let msg = stderr.isEmpty ? stdout : stderr
            throw SFTPError.transferFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 运行一次 SSH 命令调用，不返回输出；失败时抛出包含标准错误的 SFTPError。
    fileprivate static func run(_ invocation: SSHCommandInvocation) async throws {
        let (_, stderr, status) = try await run(invocation: invocation, captureOutput: false)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SFTPError.transferFailed(msg.isEmpty ? "本地进程退出码 \(status)" : msg)
        }
    }

    private static func run(
        invocation: SSHCommandInvocation,
        captureOutput: Bool
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        if !invocation.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, new in new }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        if captureOutput {
            process.standardOutput = outPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let stdout = captureOutput
                    ? String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    : ""
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (stdout, stderr, process.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    fileprivate static func controlSocketPath(for connection: SSHConnection) -> String {
        return "/tmp/ghostty_ssh_control_\(connection.id.uuidString).sock"
    }

    fileprivate static func cleanupSocket(at path: String) {
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    fileprivate static func closeControlMaster(socket: String, connection: SSHConnection) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-S", socket, "-O", "exit"] + connection.sshBaseArgs.split(separator: " ").map(String.init)
        try? process.run()
    }

    // MARK: - 解析工具

    private static func parseRsyncProgress(_ line: String) -> Double? {
        // 同时兼容 --progress 与 --info=progress2 的输出：
        // "  123,456  12%  123.45kB/s    0:00:05"
        guard let range = line.range(of: "%") else { return nil }
        let prefix = line[..<range.lowerBound]
        let components = prefix.split(separator: " ")
        guard let last = components.last,
              let percent = Double(last.trimmingCharacters(in: .whitespaces)) else { return nil }
        return percent / 100.0
    }

    private func parseLSOutput(_ output: String, showHidden: Bool) throws -> [SFTPFileItem] {
        var items: [SFTPFileItem] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("d") || trimmed.hasPrefix("-") || trimmed.hasPrefix("l") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let perms = String(parts[0])
            let size = Int64(parts[4])
            let nameParts = parts.dropFirst(8)
            let name = nameParts.joined(separator: " ")
            if name == "." || name == ".." { continue }
            if !showHidden && name.hasPrefix(".") { continue }

            let type: SFTPItemType
            switch perms.first {
            case "d": type = .directory
            case "l": type = .symlink
            case "-": type = .file
            default: type = .other
            }
            items.append(SFTPFileItem(name: name, type: type, size: size, modificationDate: nil, permissions: String(perms.dropFirst())))
        }
        return items
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func updateTask(_ task: SFTPTask, progress: Double, state: SFTPTaskState? = nil) {
        DispatchQueue.main.async {
            task.progress = progress
            if let state { task.state = state }
        }
    }
}

// MARK: - SFTP Backend

/// 统一的后端接口：执行远程命令，以及为 rsync 提供已认证的 SSH 通道。
private protocol SFTPBackend: AnyObject {
    func execute(remoteCommand: String) async throws -> String
    func withRsyncChannel<T>(_ operation: (String) async throws -> T) async throws -> T
}

/// 后端基类，实现除认证方式以外的通用逻辑。
private class BaseSFTPBackend {
    let connection: SSHConnection
    init(connection: SSHConnection) { self.connection = connection }

    /// 子类实现：构造普通 SSH 命令的调用方式。
    func sshInvocation(args: [String]) throws -> SFTPService.SSHCommandInvocation {
        fatalError("子类必须实现 sshInvocation")
    }

    /// 子类可重写：构造建立 ControlMaster 的调用方式。默认与普通命令一致。
    func controlMasterInvocation(args: [String]) throws -> SFTPService.SSHCommandInvocation {
        return try sshInvocation(args: args)
    }
}

extension BaseSFTPBackend: SFTPBackend {
    func execute(remoteCommand: String) async throws -> String {
        let args = connection.sshBaseArgs.split(separator: " ").map(String.init) + [remoteCommand]
        let invocation = try sshInvocation(args: args)
        return try await SFTPService.runCommand(invocation)
    }

    func withRsyncChannel<T>(_ operation: (String) async throws -> T) async throws -> T {
        let socket = SFTPService.controlSocketPath(for: connection)
        SFTPService.cleanupSocket(at: socket)

        var args = connection.sshBaseArgs.split(separator: " ").map(String.init)
        args.insert(contentsOf: ["-M", "-S", socket, "-f", "-N"], at: 0)
        let invocation = try controlMasterInvocation(args: args)

        do {
            try await SFTPService.run(invocation)
        } catch {
            SFTPService.cleanupSocket(at: socket)
            throw SFTPError.transferFailed("建立 SSH 控制通道失败: \(error.localizedDescription)")
        }

        guard FileManager.default.fileExists(atPath: socket) else {
            SFTPService.cleanupSocket(at: socket)
            throw SFTPError.transferFailed("SSH 控制通道未创建")
        }

        defer {
            SFTPService.closeControlMaster(socket: socket, connection: connection)
            SFTPService.cleanupSocket(at: socket)
        }

        return try await operation(socket)
    }
}

// MARK: - 密钥登录后端

private final class KeySFTPBackend: BaseSFTPBackend {
    override func sshInvocation(args: [String]) throws -> SFTPService.SSHCommandInvocation {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else {
            throw SFTPError.commandNotFound("ssh")
        }
        return SFTPService.SSHCommandInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: [:]
        )
    }
}

// MARK: - 密码登录后端

private final class PasswordSFTPBackend: BaseSFTPBackend {
    private var askpassHelperURLCache: URL?
    private var expectHelperURLCache: URL?

    override func sshInvocation(args: [String]) throws -> SFTPService.SSHCommandInvocation {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else {
            throw SFTPError.commandNotFound("ssh")
        }
        guard !connection.password.isEmpty else {
            throw SFTPError.transferFailed("密码为空")
        }
        let helper = try askpassHelperURL()
        var env = ProcessInfo.processInfo.environment
        env["GHOSTTY_ASKPASS_PASSWORD"] = connection.password
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        return SFTPService.SSHCommandInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: env
        )
    }

    override func controlMasterInvocation(args: [String]) throws -> SFTPService.SSHCommandInvocation {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else {
            throw SFTPError.commandNotFound("ssh")
        }
        guard !connection.password.isEmpty else {
            throw SFTPError.transferFailed("密码为空")
        }
        let helper = try expectHelperURL()
        var env = ProcessInfo.processInfo.environment
        env["SSHPASS"] = connection.password
        return SFTPService.SSHCommandInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/expect"),
            arguments: [helper.path, URL(fileURLWithPath: "/usr/bin/ssh").path] + args,
            environment: env
        )
    }

    private func askpassHelperURL() throws -> URL {
        if let url = askpassHelperURLCache { return url }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_askpass.sh")
        let script = """
        #!/bin/bash
        printf '%s\\n' "$GHOSTTY_ASKPASS_PASSWORD"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        askpassHelperURLCache = url
        return url
    }

    private func expectHelperURL() throws -> URL {
        if let url = expectHelperURLCache { return url }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_expect.exp")
        let script = """
        #!/usr/bin/expect -f
        set password $env(SSHPASS)
        set timeout 30
        set sshCmd [lindex $argv 0]
        set sshArgs [lrange $argv 1 end]
        log_user 0
        spawn $sshCmd {*}$sshArgs
        expect {
            -nocase "password:" { send "$password\\r" }
            timeout { exit 1 }
            eof { exit 1 }
        }
        # 密码已发送，等待 ssh 完成认证并 fork 成控制通道；超时缩短为 10 秒。
        set timeout 10
        expect eof
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        expectHelperURLCache = url
        return url
    }
}

// MARK: - 传输任务管理器

/// 管理 SFTP 上传/下载任务队列。
final class SFTPTransferManager: ObservableObject {
    static let shared = SFTPTransferManager()

    @Published private(set) var tasks: [SFTPTask] = []
    private var isRunning = false

    var activeUploadCount: Int {
        tasks.filter { $0.type == .upload && $0.isActive }.count
    }

    var activeDownloadCount: Int {
        tasks.filter { $0.type == .download && $0.isActive }.count
    }

    func addTask(_ task: SFTPTask) {
        DispatchQueue.main.async {
            self.tasks.append(task)
            self.runNext()
        }
    }

    func pauseTask(_ task: SFTPTask) {
        if task.state == .running {
            task.process?.terminate()
        }
        DispatchQueue.main.async { task.state = .paused }
    }

    func resumeTask(_ task: SFTPTask) {
        guard task.state == .paused else { return }
        DispatchQueue.main.async {
            task.state = .pending
            task.errorMessage = nil
            self.runNext()
        }
    }

    func cancelTask(_ task: SFTPTask) {
        task.process?.terminate()
        DispatchQueue.main.async { task.state = .cancelled }
    }

    func clearCompleted(for connection: SSHConnection? = nil) {
        DispatchQueue.main.async {
            if let connection {
                self.tasks.removeAll { $0.isCompleted && $0.connection.id == connection.id }
            } else {
                self.tasks.removeAll { $0.isCompleted }
            }
        }
    }

    private func runNext() {
        guard !isRunning else { return }
        guard let task = tasks.first(where: { $0.state == .pending }) else { return }
        isRunning = true
        Task {
            await execute(task)
            await MainActor.run {
                self.isRunning = false
                self.runNext()
            }
        }
    }

    private func execute(_ task: SFTPTask) async {
        await MainActor.run {
            task.errorMessage = nil
            if task.state == .pending { task.state = .running }
        }
        do {
            switch task.type {
            case .upload:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: task.localPath, isDirectory: &isDir), isDir.boolValue {
                    try await SFTPService.shared.uploadDirectory(
                        connection: task.connection,
                        localURL: URL(fileURLWithPath: task.localPath),
                        remoteDirectory: task.remotePath,
                        task: task
                    )
                } else {
                    try await SFTPService.shared.uploadFile(
                        connection: task.connection,
                        localURL: URL(fileURLWithPath: task.localPath),
                        remoteDirectory: task.remotePath,
                        task: task
                    )
                }
            case .download:
                let destURL = URL(fileURLWithPath: task.localPath)
                if task.isDirectory {
                    try await SFTPService.shared.downloadDirectory(
                        connection: task.connection,
                        remotePath: task.remotePath,
                        localDirectory: destURL,
                        task: task
                    )
                } else {
                    try await SFTPService.shared.downloadFile(
                        connection: task.connection,
                        remotePath: task.remotePath,
                        localDirectory: destURL,
                        task: task
                    )
                }
            }
            await MainActor.run {
                task.progress = 1.0
                if task.state != .cancelled && task.state != .paused {
                    task.state = .completed
                }
            }
        } catch {
            await MainActor.run {
                if task.state != .cancelled && task.state != .paused {
                    task.state = .failed
                    task.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
