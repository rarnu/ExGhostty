import Foundation
import os

/// 本地进程查询/结束工具。
enum ProcessInspector {
    private static let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.xjai.exghostty",
        category: "ProcessInspector"
    )

    /// 查询占用指定 TCP 端口监听状态的进程 PID（使用 `lsof -ti :<port>`）。
    static func pidListening(on port: UInt16) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let firstLine = text.components(separatedBy: .newlines).first,
                  let pid = Int32(firstLine) else {
                return nil
            }
            return pid
        } catch {
            return nil
        }
    }

    /// 根据 PID 获取进程名称。
    static func processName(for pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// 获取指定 PID 的直接子进程 PID 列表（使用 `pgrep -P <pid>`）。
    static func childPIDs(of pid: Int32) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return []
            }
            return text.components(separatedBy: .newlines).compactMap { Int32($0) }
        } catch {
            return []
        }
    }

    /// 使用 SIGKILL 强制结束指定 PID 的进程。
    static func forceKill(pid: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-9", "\(pid)"]
        do {
            try task.run()
        } catch {
            logger.warning("Failed to force kill PID \(pid): \(error.localizedDescription)")
        }
    }

    /// 结束指定 PID 的进程，返回是否成功。
    @discardableResult
    static func killProcess(pid: Int32) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/kill")
        task.arguments = ["-9", "\(pid)"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
