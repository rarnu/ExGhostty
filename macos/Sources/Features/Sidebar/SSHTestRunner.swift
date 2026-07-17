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

    /// 以异步流的形式返回测试过程中的步骤、日志与最终结果
    static func stream(config: SSHTestConfig) -> AsyncStream<SSHTestEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                await run(config: config, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func run(
        config: SSHTestConfig,
        continuation: AsyncStream<SSHTestEvent>.Continuation
    ) async {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            continuation.yield(.failure(TestError.sshNotFound.localizedDescription))
            continuation.finish()
            return
        }

        continuation.yield(.step("Checking system SSH command".localized))
        continuation.yield(.log("Found /usr/bin/ssh"))

        var sshArgs: [String] = ["-v", "-o", "StrictHostKeyChecking=accept-new"]
        sshArgs += commonSSHOptions(config: config)

        if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
            let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
            let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
            sshArgs += ["-J", "\(jumpUser)\(jump.host)\(jumpPort)"]
            continuation.yield(.step(L("Using jump host: %@ (%@)", jump.name, "\(jump.host)\(jumpPort)")))
        } else {
            continuation.yield(.step("Connecting directly to target host".localized))
        }

        continuation.yield(.step("Building SSH command".localized))

        let targetDescription: String
        switch config.authMode {
        case .password:
            if config.password.isEmpty {
                continuation.yield(.step("Password empty; using BatchMode for connectivity test".localized))
                sshArgs += ["-o", "BatchMode=yes"]
                targetDescription = "Password empty; testing network connectivity only".localized
            } else {
                continuation.yield(.step("Using expect to auto-enter password for authentication test".localized))
                await testWithExpect(config: config, continuation: continuation)
                return
            }
        case .key:
            if let keyPath = config.keyPath {
                guard FileManager.default.fileExists(atPath: keyPath) else {
                    continuation.yield(.failure(L("Key file does not exist: %@", keyPath)))
                    continuation.finish()
                    return
                }
                continuation.yield(.step(L("Using key authentication: %@", keyPath)))
                sshArgs += ["-i", keyPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"]
                targetDescription = "Key Authentication".localized
            } else {
                continuation.yield(.step("No key specified; using BatchMode for connectivity test".localized))
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

        continuation.yield(.log("$ ssh \(sshArgs.joined(separator: " "))"))
        continuation.yield(.step("Executing SSH test connection".localized))

        let result = await runProcess(
            executable: "/usr/bin/ssh",
            args: sshArgs,
            env: ["SSH_AUTH_SOCK": ""].merging(config.encodingEnvironment) { $1 },
            continuation: continuation
        )

        switch result {
        case .success:
            continuation.yield(.success(L("Connection test passed (%@)", targetDescription)))
        case .failure(let error):
            continuation.yield(.failure(error.localizedDescription))
        }
        continuation.finish()
    }

    private static func testWithExpect(
        config: SSHTestConfig,
        continuation: AsyncStream<SSHTestEvent>.Continuation
    ) async {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/expect") else {
            continuation.yield(.failure(TestError.expectNotFound.localizedDescription))
            continuation.finish()
            return
        }

        continuation.yield(.step("Checking system expect command".localized))
        continuation.yield(.log("Found /usr/bin/expect"))

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
        sshArgs += " \(userPrefix)\(config.host) exit"

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
            continuation.yield(.failure(L("Failed to write expect script: %@", error.localizedDescription)))
            continuation.finish()
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        continuation.yield(.log("$ expect \(tempURL.path)"))
        continuation.yield(.log("$ ssh \(sshArgs)"))
        continuation.yield(.step("Executing expect password auto-entry test".localized))

        let result = await runProcess(
            executable: "/usr/bin/expect",
            args: [tempURL.path],
            env: ["SSHPASS": config.password, "SSH_AUTH_SOCK": ""].merging(config.encodingEnvironment) { $1 },
            continuation: continuation
        )

        switch result {
        case .success:
            continuation.yield(.success("Connection test passed (password authentication)".localized))
        case .failure(let error):
            if case TestError.connectionFailed(let msg) = error, msg.contains("timed out") {
                continuation.yield(.failure("Connection timed out. Check address, port, and jump host reachability.".localized))
            } else {
                continuation.yield(.failure(error.localizedDescription))
            }
        }
        continuation.finish()
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
        continuation: AsyncStream<SSHTestEvent>.Continuation
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
                            flushBuffer(&outBuffer, continuation: continuation)
                        }
                    } catch {
                        // 读取结束或被取消时退出。
                    }
                }

                group.addTask {
                    do {
                        for try await byte in errPipe.fileHandleForReading.bytes {
                            errBuffer.append(byte)
                            flushBuffer(&errBuffer, continuation: continuation)
                        }
                    } catch {
                        // 读取结束或被取消时退出。
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

                flushBuffer(&outBuffer, continuation: continuation)
                flushBuffer(&errBuffer, continuation: continuation)
                flushRemaining(&outBuffer, continuation: continuation)
                flushRemaining(&errBuffer, continuation: continuation)

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
        continuation: AsyncStream<SSHTestEvent>.Continuation
    ) {
        while let range = data.range(of: Data("\n".utf8)) {
            let lineData = data.subdata(in: 0..<range.lowerBound)
            data.removeSubrange(0..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                continuation.yield(.log(line))
            }
        }
    }

    private static func flushRemaining(
        _ data: inout Data,
        continuation: AsyncStream<SSHTestEvent>.Continuation
    ) {
        if !data.isEmpty,
           let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            continuation.yield(.log(line))
        }
        data.removeAll()
    }
}
