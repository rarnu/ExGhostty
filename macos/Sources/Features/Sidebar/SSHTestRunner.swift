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
            let task = Task {
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

    private static func runProcess(
        executable: String,
        args: [String],
        env: [String: String],
        continuation: AsyncStream<SSHTestEvent>.Continuation
    ) async -> Result<Void, Error> {
        do {
            let stdout = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: executable),
                arguments: args,
                environment: ProcessInfo.processInfo.environment.merging(env) { $1 }
            )
            for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    continuation.yield(.log(trimmed))
                }
            }
            return .success(())
        } catch let error as ProcessRunnerError {
            if case .executionFailed(_, let status, let stderr) = error {
                for line in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        continuation.yield(.log(trimmed))
                    }
                }
                if status == 124 {
                    return .failure(TestError.connectionFailed("Connection timed out".localized))
                } else {
                    return .failure(TestError.connectionFailed(L("SSH process exit code %d", status)))
                }
            }
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }
}
