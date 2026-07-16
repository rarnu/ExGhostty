import Foundation

// MARK: - 错误

/// SSH 命令执行错误。
enum SSHCommandError: Error, LocalizedError {
    case commandNotFound(String)
    case controlChannelFailed(String)
    case executionFailed(command: String, stdout: String, stderr: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let cmd):
            return "找不到命令: \(cmd)"
        case .controlChannelFailed(let msg):
            return "建立 SSH 控制通道失败: \(msg)"
        case .executionFailed(let command, _, let stderr, let status):
            let msg = stderr.isEmpty ? "本地进程退出码 \(status)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(command)] \(msg)"
        }
    }
}

// MARK: - 命令调用描述

private struct SSHCommandInvocation {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

/// 可用于长时间运行（流式）进程的 SSH 调用描述。
struct SSHStreamingInvocation {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

// MARK: - SSH 命令执行器

/// 负责在 SSH 连接上执行远程命令，以及创建/复用 SSH ControlMaster 通道。
///
/// 从 `SFTPService` 中抽离出来，供 SFTP、会话复用、端口转发等模块共用。
actor SSHCommandExecutor {
    static let shared = SSHCommandExecutor()

    private init() {}

    /// 执行任意远程命令并返回标准输出。
    func execute(
        remoteCommand: String,
        connection: SSHConnection
    ) async throws -> String {
        let backend = try backend(for: connection)
        let args = connection.sshBaseArgs.split(separator: " ").map(String.init) + [remoteCommand]
        let invocation = try backend.sshInvocation(args: args)
        return try await runCommand(invocation)
    }

    /// 构造一个可用于长时间运行（流式）进程的 SSH 调用描述。
    ///
    /// 调用方负责创建并管理 `Process` 的生命周期。
    func streamingInvocation(
        remoteCommand: String,
        connection: SSHConnection
    ) async throws -> SSHStreamingInvocation {
        let backend = try backend(for: connection)
        let args = connection.sshBaseArgs.split(separator: " ").map(String.init) + [remoteCommand]
        let invocation = try backend.sshInvocation(args: args)
        return SSHStreamingInvocation(
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            environment: invocation.environment
        )
    }

    /// 为指定连接建立一个 SSH ControlMaster 通道，并在通道可用期间执行 `operation`。
    ///
    /// `operation` 接收控制 socket 路径，可用于 rsync 等需要共享 SSH 连接的场景。
    func withControlChannel<T>(
        connection: SSHConnection,
        operation: (String) async throws -> T
    ) async throws -> T {
        let backend = try backend(for: connection)
        let socket = Self.controlSocketPath(for: connection)
        Self.cleanupSocket(at: socket)

        var args = connection.sshBaseArgs.split(separator: " ").map(String.init)
        args.insert(contentsOf: ["-M", "-S", socket, "-f", "-N"], at: 0)
        let invocation = try backend.controlMasterInvocation(args: args)

        do {
            try await ProcessRunner.runSilently(
                executable: invocation.executableURL,
                arguments: invocation.arguments,
                environment: invocation.environment
            )
        } catch {
            Self.cleanupSocket(at: socket)
            throw SSHCommandError.controlChannelFailed(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: socket) else {
            Self.cleanupSocket(at: socket)
            throw SSHCommandError.controlChannelFailed("SSH 控制通道未创建")
        }

        defer {
            Self.closeControlMaster(socket: socket, connection: connection)
            Self.cleanupSocket(at: socket)
        }

        return try await operation(socket)
    }

    // MARK: - 内部辅助

    private func backend(for connection: SSHConnection) throws -> SSHBackend {
        switch connection.authMode {
        case .key: return KeySSHBackend(connection: connection)
        case .password: return PasswordSSHBackend(connection: connection)
        }
    }

    private func runCommand(_ invocation: SSHCommandInvocation) async throws -> String {
        do {
            return try await ProcessRunner.run(
                executable: invocation.executableURL,
                arguments: invocation.arguments,
                environment: invocation.environment
            )
        } catch let error as ProcessRunnerError {
            if case .executionFailed(let cmd, let status, let stderr) = error {
                throw SSHCommandError.executionFailed(command: cmd, stdout: "", stderr: stderr, status: status)
            }
            throw error
        }
    }

    private static func controlSocketPath(for connection: SSHConnection) -> String {
        "/tmp/ghostty_ssh_control_\(connection.id.uuidString).sock"
    }

    private static func cleanupSocket(at path: String) {
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func closeControlMaster(socket: String, connection: SSHConnection) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-S", socket, "-O", "exit"] + connection.sshBaseArgs.split(separator: " ").map(String.init)
        try? process.run()
    }
}

// MARK: - Backend

private protocol SSHBackend: AnyObject {
    func sshInvocation(args: [String]) throws -> SSHCommandInvocation
    func controlMasterInvocation(args: [String]) throws -> SSHCommandInvocation
}

private class BaseSSHBackend {
    let connection: SSHConnection
    init(connection: SSHConnection) { self.connection = connection }

    func sshInvocation(args: [String]) throws -> SSHCommandInvocation {
        fatalError("子类必须实现 sshInvocation")
    }

    func controlMasterInvocation(args: [String]) throws -> SSHCommandInvocation {
        return try sshInvocation(args: args)
    }
}

extension BaseSSHBackend: SSHBackend {}

// MARK: - 密钥登录后端

private final class KeySSHBackend: BaseSSHBackend {
    override func sshInvocation(args: [String]) throws -> SSHCommandInvocation {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else {
            throw SSHCommandError.commandNotFound("ssh")
        }
        return SSHCommandInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: [:]
        )
    }
}

// MARK: - 密码登录后端

private final class PasswordSSHBackend: BaseSSHBackend {
    private var askpassHelperURLCache: URL?
    private var expectHelperURLCache: URL?

    override func sshInvocation(args: [String]) throws -> SSHCommandInvocation {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else {
            throw SSHCommandError.commandNotFound("ssh")
        }
        guard !connection.password.isEmpty else {
            throw SSHCommandError.executionFailed(command: "ssh", stdout: "", stderr: "密码为空", status: 1)
        }
        let helper = try askpassHelperURL()
        var env = ProcessInfo.processInfo.environment
        env["GHOSTTY_ASKPASS_PASSWORD"] = connection.password
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        return SSHCommandInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: env
        )
    }

    override func controlMasterInvocation(args: [String]) throws -> SSHCommandInvocation {
        guard FileManager.default.fileExists(atPath: "/usr/bin/ssh") else {
            throw SSHCommandError.commandNotFound("ssh")
        }
        guard !connection.password.isEmpty else {
            throw SSHCommandError.executionFailed(command: "ssh", stdout: "", stderr: "密码为空", status: 1)
        }
        let helper = try expectHelperURL()
        var env = ProcessInfo.processInfo.environment
        env["SSHPASS"] = connection.password
        return SSHCommandInvocation(
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
