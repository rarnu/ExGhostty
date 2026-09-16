import Foundation

// MARK: - 测试配置

struct SSHTestConfig {
    let host: String
    let port: UInt16
    let username: String
    let authMode: SSHAuthMode
    let password: String
    let keyPath: String?
    let connectionMethod: SSHConnectionMethod
    let jumpHost: SSHConnection?
    let timeoutMs: UInt32
    let heartbeatMs: UInt32
    let encoding: String
    let x11Forwarding: Bool
    /// 作为桌面访问（sshdesk）：连接测试通过后追加桌面可用性测试。
    let desktopAccess: Bool

    var encodingEnvironment: [String: String] {
        [
            "LANG": encoding,
            "LC_ALL": encoding,
        ]
    }
}

// MARK: - 测试事件

enum SSHTestEvent {
    case step(String)
    case log(String)
    case success(String)
    case failure(String)
}

// MARK: - 测试执行器

enum SSHTester {
    enum TestError: LocalizedError {
        case sshNotFound
        case expectNotFound
        case invalidPort
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .sshNotFound:
                return "System ssh command not found".localized
            case .expectNotFound:
                return "expect not found; cannot test password login".localized
            case .invalidPort:
                return "Invalid port number".localized
            case .connectionFailed(let msg):
                return msg
            }
        }
    }

    /// 在后台任务中执行测试，通过回调逐条投递事件。
    /// 返回的任务可用于取消测试；取消时会终止底层进程。
    @discardableResult
    static func runTest(
        config: SSHTestConfig,
        onEvent: @escaping (SSHTestEvent) -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            await run(config: config, emit: onEvent)
        }
    }

    /// 以异步流的形式返回测试过程中的步骤、日志与最终结果（保留用于兼容）。
    static func stream(config: SSHTestConfig) -> AsyncStream<SSHTestEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                await run(config: config) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func run(
        config: SSHTestConfig,
        emit: @escaping (SSHTestEvent) -> Void
    ) async {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            emit(.failure(TestError.sshNotFound.localizedDescription))
            return
        }

        emit(.step("Checking system SSH command".localized))
        emit(.log("Found /usr/bin/ssh"))

        var sshArgs: [String] = ["-v", "-o", "StrictHostKeyChecking=accept-new"]
        sshArgs += commonSSHOptions(config: config)

        if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
            let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
            let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
            sshArgs += ["-J", "\(jumpUser)\(jump.host)\(jumpPort)"]
            emit(.step(L("Using jump host: %@ (%@)", jump.name, "\(jump.host)\(jumpPort)")))
        } else {
            emit(.step("Connecting directly to target host".localized))
        }

        emit(.step("Building SSH command".localized))

        let targetDescription: String
        switch config.authMode {
        case .password:
            if config.password.isEmpty {
                emit(.step("Password empty; using BatchMode for connectivity test".localized))
                sshArgs += ["-o", "BatchMode=yes"]
                targetDescription = "Password empty; testing network connectivity only".localized
            } else {
                emit(.step("Using expect to auto-enter password for authentication test".localized))
                let authResult = await testWithExpect(config: config, remoteCommand: "exit", emit: emit)
                switch authResult {
                case .success:
                    if config.desktopAccess {
                        await runDesktopTest(config: config, emit: emit)
                    } else {
                        emit(.success("Connection test passed (password authentication)".localized))
                    }
                case .failure(let error):
                    if case TestError.connectionFailed(let msg) = error, msg.contains("timed out") {
                        emit(.failure("Connection timed out. Check address, port, and jump host reachability.".localized))
                    } else {
                        emit(.failure(error.localizedDescription))
                    }
                }
                return
            }
        case .key:
            if let keyPath = config.keyPath {
                guard FileManager.default.fileExists(atPath: keyPath) else {
                    emit(.failure(L("Key file does not exist: %@", keyPath)))
                    return
                }
                emit(.step(L("Using key authentication: %@", keyPath)))
                sshArgs += ["-i", keyPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"]
                targetDescription = "Key Authentication".localized
            } else {
                emit(.step("No key specified; using BatchMode for connectivity test".localized))
                sshArgs += ["-o", "BatchMode=yes"]
                targetDescription = "No key specified; testing network connectivity only".localized
            }
        }

        let userPrefix = config.username.isEmpty ? "" : "\(config.username)@"
        sshArgs += ["\(userPrefix)\(config.host)"]
        if config.port != 22 {
            sshArgs += ["-p", String(config.port)]
        }
        sshArgs += ["exit"]

        emit(.log("$ ssh \(sshArgs.joined(separator: " "))"))
        emit(.step("Executing SSH test connection".localized))

        let result = await runProcess(
            executable: "/usr/bin/ssh",
            args: sshArgs,
            env: ["SSH_AUTH_SOCK": ""].merging(config.encodingEnvironment) { $1 },
            emit: emit
        )

        switch result {
        case .success:
            if config.desktopAccess {
                await runDesktopTest(config: config, emit: emit)
            } else {
                emit(.success(L("Connection test passed (%@)", targetDescription)))
            }
        case .failure(let error):
            emit(.failure(error.localizedDescription))
        }
    }

    /// 桌面访问测试：通过 `sshdesk-agent info` 探测目标主机是否安装并响应
    /// sshdesk 服务（精确的 `desktop` 选择器会进入图形会话流，不适合测试）。
    private static func runDesktopTest(
        config: SSHTestConfig,
        emit: @escaping (SSHTestEvent) -> Void
    ) async {
        emit(.step("Testing desktop access (sshdesk)".localized))

        let result: Result<Void, Error>
        if config.authMode == .password && !config.password.isEmpty {
            result = await testWithExpect(config: config, remoteCommand: "sshdesk-agent info", emit: emit)
        } else {
            var sshArgs: [String] = ["-o", "BatchMode=yes"]
            sshArgs += commonSSHOptions(config: config)

            if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
                let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
                let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
                sshArgs += ["-J", "\(jumpUser)\(jump.host)\(jumpPort)"]
            }

            if config.authMode == .key, let keyPath = config.keyPath {
                sshArgs += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
            }

            let userPrefix = config.username.isEmpty ? "" : "\(config.username)@"
            sshArgs += ["\(userPrefix)\(config.host)"]
            if config.port != 22 {
                sshArgs += ["-p", String(config.port)]
            }
            sshArgs += ["sshdesk-agent", "info"]

            emit(.log("$ ssh \(sshArgs.joined(separator: " "))"))
            result = await runProcess(
                executable: "/usr/bin/ssh",
                args: sshArgs,
                env: ["SSH_AUTH_SOCK": ""].merging(config.encodingEnvironment) { $1 },
                emit: emit
            )
        }

        switch result {
        case .success:
            emit(.success("Connection and desktop access tests passed (sshdesk service available)".localized))
        case .failure:
            emit(.failure("Connection test passed, but desktop access test failed: sshdesk service is not available on the target host".localized))
        }
    }

    /// 通过 expect 自动回答密码提示执行一次 SSH 远程命令。
    /// 只投递步骤与日志事件，最终结果由调用方根据返回值投递。
    private static func testWithExpect(
        config: SSHTestConfig,
        remoteCommand: String,
        emit: @escaping (SSHTestEvent) -> Void
    ) async -> Result<Void, Error> {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/expect") else {
            return .failure(TestError.expectNotFound)
        }

        emit(.step("Checking system expect command".localized))
        emit(.log("Found /usr/bin/expect"))

        var sshArgs = "-v -o StrictHostKeyChecking=accept-new " + commonSSHOptions(config: config).joined(separator: " ")

        if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
            let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
            let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
            sshArgs += " -J \(jumpUser)\(jump.host)\(jumpPort)"
        }

        if config.port != 22 {
            sshArgs += " -p \(config.port)"
        }

        let userPrefix = config.username.isEmpty ? "" : "\(config.username)@"
        sshArgs += " \(userPrefix)\(config.host) \(remoteCommand)"

        let script = #"""
        set timeout 60
        set password $env(SSHPASS)
        spawn /usr/bin/ssh \#(sshArgs)
        set attempts 0
        expect {
            -nocase "password:" {
                if { $attempts >= 3 } {
                    puts "Authentication failed"
                    exit 1
                }
                send "$password\r"
                incr attempts
                exp_continue
            }
            timeout {
                puts "Connection timed out"
                exit 124
            }
            eof {
                catch wait result
                exit [lindex $result 3]
            }
        }
        """#

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_test_\(UUID().uuidString).exp")

        do {
            try script.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(error)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        emit(.log("$ expect \(tempURL.path)"))
        emit(.log("$ ssh \(sshArgs)"))
        emit(.step("Executing expect password auto-entry test".localized))

        return await runProcess(
            executable: "/usr/bin/expect",
            args: [tempURL.path],
            env: ["SSHPASS": config.password, "SSH_AUTH_SOCK": ""].merging(config.encodingEnvironment) { $1 },
            emit: emit
        )
    }

    private static func commonSSHOptions(config: SSHTestConfig) -> [String] {
        var options: [String] = []
        let timeoutSec = max(1, Double(config.timeoutMs) / 1000.0)
        options += ["-o", "ConnectTimeout=\(timeoutSec)"]
        if config.heartbeatMs > 0 {
            let heartbeatSec = max(1, Int(config.heartbeatMs / 1000))
            options += ["-o", "ServerAliveInterval=\(heartbeatSec)", "-o", "ServerAliveCountMax=10"]
        }
        if config.x11Forwarding {
            options += ["-Y"]
        }
        return options
    }

    private static let processTimeout: TimeInterval = 60.0

    private static func runProcess(
        executable: String,
        args: [String],
        env: [String: String],
        emit: @escaping (SSHTestEvent) -> Void
    ) async -> Result<Void, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failure(error)
        }

        // 超时兜底：若进程长时间不退出则强制终止。
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(processTimeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        var outBuffer = Data()
        var errBuffer = Data()

        return await withTaskCancellationHandler(operation: {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await byte in outPipe.fileHandleForReading.bytes {
                            outBuffer.append(byte)
                            flushBuffer(&outBuffer, emit: emit)
                        }
                    } catch {
                        // 读取失败时结束该读取任务
                    }
                }

                group.addTask {
                    do {
                        for try await byte in errPipe.fileHandleForReading.bytes {
                            errBuffer.append(byte)
                            flushBuffer(&errBuffer, emit: emit)
                        }
                    } catch {
                        // 读取失败时结束该读取任务
                    }
                }

                group.addTask {
                    process.waitUntilExit()
                    timeoutTask.cancel()

                    // 终止可能仍在运行的子进程（例如 expect 启动的 ssh）。
                    let pid = Int32(process.processIdentifier)
                    for child in ProcessInspector.childPIDs(of: pid) {
                        ProcessInspector.forceKill(pid: child)
                    }
                }

                // 等待任一任务完成（通常是等待进程退出的任务），然后取消读取任务。
                _ = await group.next()
                group.cancelAll()
                // 等待被取消的任务结束。
                while await group.next() != nil {}

                flushBuffer(&outBuffer, emit: emit)
                flushBuffer(&errBuffer, emit: emit)
                flushRemaining(&outBuffer, emit: emit)
                flushRemaining(&errBuffer, emit: emit)

                let status = process.terminationStatus
                if status == 0 {
                    return .success(())
                }
                let stderr = String(data: errBuffer, encoding: .utf8) ?? ""
                if status == 124 || stderr.localizedLowercase.contains("timed out") {
                    return .failure(TestError.connectionFailed("Connection timed out".localized))
                }
                return .failure(TestError.connectionFailed(L("SSH process exit code %d", status)))
            }
        }, onCancel: {
            process.terminate()
            let pid = Int32(process.processIdentifier)
            for child in ProcessInspector.childPIDs(of: pid) {
                ProcessInspector.forceKill(pid: child)
            }
        })
    }

    private static func flushBuffer(
        _ data: inout Data,
        emit: @escaping (SSHTestEvent) -> Void
    ) {
        while let range = data.range(of: Data("\n".utf8)) {
            let lineData = data.subdata(in: 0..<range.lowerBound)
            data.removeSubrange(0..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                emit(.log(line))
            }
        }
    }

    private static func flushRemaining(
        _ data: inout Data,
        emit: @escaping (SSHTestEvent) -> Void
    ) {
        if !data.isEmpty,
           let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            emit(.log(line))
        }
        data.removeAll()
    }
}
