import Foundation

/// 为 SSH X11 转发收集本地 X server 所需的环境变量。
/// GUI 应用通常不会继承 shell 中的 DISPLAY，因此需要从 launchd 用户域回退获取。
struct SSHX11Environment {
    /// 当前系统是否具备 X11 转发条件（即能否拿到本地 DISPLAY）
    static var isAvailable: Bool {
        current["DISPLAY"] != nil
    }

    static var current: [String: String] {
        var env: [String: String] = [:]

        var display = ProcessInfo.processInfo.environment["DISPLAY"]
        var xauthority = ProcessInfo.processInfo.environment["XAUTHORITY"]

        // GUI 应用可能缺少 DISPLAY，尝试从 launchd 用户域读取
        if display == nil || display!.isEmpty {
            display = launchctlGetenv("DISPLAY")
        }
        if xauthority == nil || xauthority!.isEmpty {
            xauthority = launchctlGetenv("XAUTHORITY")
        }

        if let d = display, !d.isEmpty {
            env["DISPLAY"] = d
        }

        if let x = xauthority, !x.isEmpty {
            env["XAUTHORITY"] = x
        } else if env["DISPLAY"] != nil {
            // 若未显式设置 XAUTHORITY，回退到用户主目录下的默认文件
            let homeXauth = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".Xauthority")
                .path
            if FileManager.default.fileExists(atPath: homeXauth) {
                env["XAUTHORITY"] = homeXauth
            }
        }

        // 确保 ssh 能找到 macOS 上的 xauth 工具
        if env["DISPLAY"] != nil {
            let x11Paths = ["/opt/X11/bin", "/usr/X11/bin"]
            let existingPaths = ProcessInfo.processInfo.environment["PATH"] ?? ""
            let missingPaths = x11Paths.filter { path in
                !existingPaths.split(separator: ":").contains { $0 == path }
            }
            if !missingPaths.isEmpty {
                env["PATH"] = (missingPaths + [existingPaths]).joined(separator: ":")
            }
        }

        return env
    }

    private static func launchctlGetenv(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["getenv", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        } catch {
            return nil
        }
    }
}
