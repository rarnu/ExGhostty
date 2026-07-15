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
                return "未找到系统 ssh 命令"
            case .expectNotFound:
                return "未找到 expect，无法测试密码登录"
            case .invalidPort:
                return "端口号无效"
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

        continuation.yield(.step("检查系统 SSH 命令"))
        continuation.yield(.log("Found /usr/bin/ssh"))

        var sshArgs: [String] = ["-v", "-o", "StrictHostKeyChecking=accept-new"]
        sshArgs += commonSSHOptions(config: config)

        if config.connectionMethod == .jumpHost, let jump = config.jumpHost {
            let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
            let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
            sshArgs += ["-J", "\(jumpUser)\(jump.host)\(jumpPort)"]
            continuation.yield(.step("使用跳板机：\(jump.name) (\(jump.host)\(jumpPort))"))
        } else {
            continuation.yield(.step("直接连接目标主机"))
        }

        continuation.yield(.step("构建 SSH 命令"))

        let targetDescription: String
        switch config.authMode {
        case .password:
            if config.password.isEmpty {
                continuation.yield(.step("密码为空，使用 BatchMode 进行连通性测试"))
                sshArgs += ["-o", "BatchMode=yes"]
                targetDescription = "密码为空，仅测试网络连通性"
            } else {
                continuation.yield(.step("使用 expect 自动输入密码进行认证测试"))
                await testWithExpect(config: config, continuation: continuation)
                return
            }
        case .key:
            if let keyPath = config.keyPath {
                guard FileManager.default.fileExists(atPath: keyPath) else {
                    continuation.yield(.failure("密钥文件不存在：\(keyPath)"))
                    continuation.finish()
                    return
                }
                continuation.yield(.step("使用密钥认证：\(keyPath)"))
                sshArgs += ["-i", keyPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"]
                targetDescription = "密钥认证"
            } else {
                continuation.yield(.step("未指定密钥，使用 BatchMode 进行连通性测试"))
                sshArgs += ["-o", "BatchMode=yes"]
                targetDescription = "密钥为空，仅测试网络连通性"
            }
        }

        let userPrefix = config.username.isEmpty ? "" : "\(config.username)@"
        sshArgs += ["\(userPrefix)\(config.host)"]
        if config.port != 22 {
            sshArgs += ["-p", String(config.port)]
        }
        sshArgs += ["exit"]

        continuation.yield(.log("$ ssh \(sshArgs.joined(separator: " "))"))
        continuation.yield(.step("执行 SSH 测试连接"))

        let result = await runProcess(
            executable: "/usr/bin/ssh",
            args: sshArgs,
            env: ["SSH_AUTH_SOCK": ""].merging(config.encodingEnvironment) { $1 },
            continuation: continuation
        )

        switch result {
        case .success:
            continuation.yield(.success("连接测试通过（\(targetDescription)）"))
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

        continuation.yield(.step("检查系统 expect 命令"))
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
            continuation.yield(.failure("写入 expect 脚本失败：\(error.localizedDescription)"))
            continuation.finish()
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        continuation.yield(.log("$ expect \(tempURL.path)"))
        continuation.yield(.log("$ ssh \(sshArgs)"))
        continuation.yield(.step("执行 expect 自动输入密码测试"))

        let result = await runProcess(
            executable: "/usr/bin/expect",
            args: [tempURL.path],
            env: ["SSHPASS": config.password, "SSH_AUTH_SOCK": ""].merging(config.encodingEnvironment) { $1 },
            continuation: continuation
        )

        switch result {
        case .success:
            continuation.yield(.success("连接测试通过（密码认证）"))
        case .failure(let error):
            if case TestError.connectionFailed(let msg) = error, msg.contains("timed out") {
                continuation.yield(.failure("连接超时，请检查地址、端口及跳板机可达性"))
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
                    return .failure(TestError.connectionFailed("连接超时"))
                } else {
                    return .failure(TestError.connectionFailed("SSH 进程退出码 \(status)"))
                }
            }
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }
}
