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
}

// MARK: - 测试事件

enum SSHTestEvent {
    case step(String)
    case log(String)
    case success(String)
    case failure(String)
}

// MARK: - 输出缓冲 Actor

/// 将子进程输出按行拆分的线程安全缓冲
private actor OutputBuffer {
    private var data = Data()
    private let continuation: AsyncStream<SSHTestEvent>.Continuation

    init(continuation: AsyncStream<SSHTestEvent>.Continuation) {
        self.continuation = continuation
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        data.append(newData)
        var searchStart = 0
        while let newlineIndex = data[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = data[searchStart..<newlineIndex]
            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                continuation.yield(.log(line))
            }
            searchStart = newlineIndex + 1
        }
        if searchStart > 0 {
            data.removeSubrange(0..<searchStart)
        }
    }

    func flush() {
        if !data.isEmpty,
           let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !line.isEmpty {
            continuation.yield(.log(line))
        }
        data.removeAll()
    }
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

        var sshArgs: [String] = [
            "-v",
            "-o", "ConnectTimeout=30",
            "-o", "StrictHostKeyChecking=accept-new",
        ]

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
            env: ["SSH_AUTH_SOCK": ""],
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

        var sshArgs = "-v -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new"

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
            env: ["SSHPASS": config.password, "SSH_AUTH_SOCK": ""],
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

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = OutputBuffer(continuation: continuation)

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await buffer.append(data) }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure(error)
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        await buffer.flush()

        if process.terminationStatus == 0 {
            return .success(())
        } else if process.terminationStatus == 124 {
            return .failure(TestError.connectionFailed("连接超时"))
        } else {
            return .failure(TestError.connectionFailed("SSH 进程退出码 \(process.terminationStatus)"))
        }
    }
}
