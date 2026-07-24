import Foundation

/// 本地进程/shell 命令执行错误。
enum ProcessRunnerError: Error, LocalizedError {
    case executionFailed(command: String, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let command, let status, let stderr):
            let msg = stderr.isEmpty ? L("Local process exit code %d", status) : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(command)] \(msg)"
        }
    }
}

/// 通用本地进程/Shell 命令执行器。
///
/// 封装 `Process` 的异步运行、输出捕获、错误处理，以及登录 shell 命令执行。
enum ProcessRunner {
    /// 运行一个已配置好的 `Process`，返回标准输出、标准错误和退出码。
    ///
    /// stdout/stderr 在进程运行期间由并发任务持续排空（读到 EOF），而不是等进程
    /// 终止后才读——否则输出超过管道缓冲区（64KB）时，子进程写满管道阻塞、永不终止，
    /// 读取方又在等终止，双方死锁。
    static func run(
        _ process: Process,
        captureOutput: Bool = true
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let outPipe = Pipe()
        let errPipe = Pipe()

        if captureOutput {
            process.standardOutput = outPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = errPipe

        // 进程运行期间持续读到 EOF;进程退出时写端关闭,读取任务自然结束。
        // readDataToEndOfFile 是阻塞调用,放在 detached 任务里执行。
        async let outDataTask: Data = Task.detached {
            captureOutput ? outPipe.fileHandleForReading.readDataToEndOfFile() : Data()
        }.value
        async let errDataTask: Data = Task.detached {
            errPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // 启动失败时写端仍在 Pipe 手中,必须关闭,否则读取任务永远等不到 EOF。
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }

        let outData = await outDataTask
        let errData = await errDataTask
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (stdout, stderr, status)
    }

    /// 运行指定可执行文件和参数，返回标准输出；失败时抛出包含 stderr 的错误。
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let (stdout, stderr, status) = try await run(process)
        if status == 0 { return stdout }
        let cmd = ([executable.path] + arguments).joined(separator: " ")
        throw ProcessRunnerError.executionFailed(command: cmd, status: status, stderr: stderr)
    }

    /// 运行指定可执行文件和参数，仅检查退出码；失败时抛出包含 stderr 的错误。
    static func runSilently(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let (_, stderr, status) = try await run(process, captureOutput: false)
        if status == 0 { return }
        let cmd = ([executable.path] + arguments).joined(separator: " ")
        throw ProcessRunnerError.executionFailed(command: cmd, status: status, stderr: stderr)
    }

    /// 运行 shell 命令（默认使用登录 shell，以加载 `.zshrc` / `.bash_profile` 等）。
    /// 返回标准输出；失败时抛出包含 stderr 的错误。
    static func run(
        shellCommand: String,
        loginShell: Bool = true
    ) async throws -> String {
        let shell = defaultShell()
        var arguments = ["-c", shellCommand]
        if loginShell {
            arguments.insert("-l", at: 0)
        }
        return try await run(executable: URL(fileURLWithPath: shell), arguments: arguments)
    }

    private static func defaultShell() -> String {
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            return "/bin/zsh"
        } else if FileManager.default.isExecutableFile(atPath: "/bin/bash") {
            return "/bin/bash"
        } else {
            return "/bin/sh"
        }
    }
}
