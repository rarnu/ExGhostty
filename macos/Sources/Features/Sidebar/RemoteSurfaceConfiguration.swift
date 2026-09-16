import AppKit
import Foundation

/// 为 SSH / Telnet 连接构建终端 surface 配置（expect 包装命令 + 环境变量）。
///
/// 打开连接标签页与分屏（Cmd+D 等）共用此构建逻辑，保证分屏出来的终端
/// 与当前终端是同一个远程连接，而不是本地终端。
enum RemoteSurfaceConfiguration {
    /// 构建指定连接的 surface 配置。
    /// - Parameters:
    ///   - conn: SSH / Telnet 连接。
    ///   - gridSize: 当前终端的行列数，用于 SSH expect 脚本初始化 PTY 尺寸；nil 时按 24x80。
    /// - Returns: 配置；Telnet 可执行文件不存在时返回 nil（调用方负责提示）。
    static func make(for conn: SSHConnection, gridSize: (rows: Int, cols: Int)?) -> Ghostty.SurfaceConfiguration? {
        switch conn.type {
        case .ssh:
            return makeSSH(conn, gridSize: gridSize ?? (rows: 24, cols: 80))
        case .telnet:
            return makeTelnet(conn)
        }
    }

    /// 读取设置窗口配置的 term 值（Terminal -> Term）。直接从配置文件读取，
    /// 保证新开的 SSH/Telnet 会话总是使用最新设置，即使应用内配置尚未重载。
    /// 未设置时回退到 xterm-256color（SSH 场景兼容性最好的默认值）。
    private static func configuredTerm() -> String {
        if let url = (NSApp.delegate as? AppDelegate)?.ghostty.configFileURL,
           let value = ConfigFileWriter(url: url).firstValue(for: "term"),
           !value.isEmpty {
            return value
        }
        return "xterm-256color"
    }

    // MARK: - SSH

    private static func makeSSH(_ conn: SSHConnection, gridSize: (rows: Int, cols: Int)) -> Ghostty.SurfaceConfiguration {
        var cfg = Ghostty.SurfaceConfiguration()
        let term = configuredTerm()

        // 把当前终端的真实行列数传给 expect，避免 expect 子进程读到的 stdin 尺寸错误。
        cfg.environmentVariables["GHOSTTY_ROWS"] = "\(gridSize.rows)"
        cfg.environmentVariables["GHOSTTY_COLS"] = "\(gridSize.cols)"
        cfg.environmentVariables["TERM"] = term

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_\(conn.id.uuidString).exp")
        let reconnectPrompt = "Press any key to reconnect".localized.tclEscaped

        let syncPtyProc = """
        proc sync_ssh_pty {} {
            global spawn_out
            global synced_rows synced_cols
            if {[catch {
                # 先尝试 expect 内置 stty 读当前 PTY 尺寸（iTerm2 等脚本的标准做法）。
                if {[catch {
                    set rows [stty rows]
                    set cols [stty columns]
                } tty_err]} {
                    set rows $env(GHOSTTY_ROWS)
                    set cols $env(GHOSTTY_COLS)
                }
                # 尺寸没有实际变化时跳过。远端 tmux 对每次 resize 都会整体重绘，
                # 并把 copy-mode 的滚动位置重置到最底部，因此无谓的 resize
                # 必须杜绝，否则用户上滚查看历史时会被频繁拉回底部。
                if {![info exists synced_rows] || $synced_rows != $rows
                    || ![info exists synced_cols] || $synced_cols != $cols} {
                    stty rows $rows columns $cols < $spawn_out(slave,name)
                    set synced_rows $rows
                    set synced_cols $cols
                }
            } err]} {
                # 忽略 PTY 尺寸同步失败
            }
        }

        proc schedule_sync_ssh_pty {} {
            global sync_timer
            if {[info exists sync_timer]} {
                catch { after cancel $sync_timer }
            }
            # 去抖：拖动窗口/分屏动画会产生 SIGWINCH 风暴，每个中间尺寸都会令
            # 远端 tmux 重绘并重置滚动位置。只在尺寸稳定 200ms 后同步最终尺寸。
            set sync_timer [after 200 sync_ssh_pty]
        }
        """

        // 「用户身份」：登录后自动 sudo su 到配置的用户。
        // 远端命令先打印一个随机标记再 exec 登录 shell，expect 匹配到标记即表示远端 shell
        // 已就绪——避免盲发切换命令：过早发送的命令会被首次连接的主机密钥确认提示（yes/no）
        // 吞掉，导致连接中止。标记匹配超时则放弃本次自动切换，终端停留在登录用户。
        // 桌面访问（sshdesk）直接进入图形会话，不经过登录 shell，身份切换不适用。
        let identity = conn.desktopAccess ? nil : conn.effectiveIdentity
        var spawnLine = "spawn /usr/bin/ssh \(conn.sshBaseArgs)"
        if conn.desktopAccess {
            // sshdesk：只有精确的远端命令 `desktop` 会进入图形会话，且必须分配 PTY（-t）。
            spawnLine = "spawn /usr/bin/ssh -t \(conn.sshBaseArgs) desktop"
        }
        var identitySnippet = ""
        if let identity {
            let token = String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
            let marker = "GHOSTTY_IDENTITY_READY_\(token)"
            // 标记打印后立即用空格覆盖擦除（\r + 等长空格 + \r，只用 POSIX 的 \r，
            // 不依赖 \033 等非 POSIX printf 转义），终端上不留痕迹；
            // expect 匹配的是字节流，不受影响。Tcl {} 内原样传递：\r 由远端
            // printf 解释，$SHELL 由远端 shell 展开。
            let erase = String(repeating: " ", count: marker.count)
            spawnLine = "spawn /usr/bin/ssh -t \(conn.sshBaseArgs) {printf '\(marker)\\r\(erase)\\r'; exec $SHELL -l}"
            let hasIdentityPassword = !(identity.sudoPassword?.isEmpty ?? true)
            let passwordSnippet = """
                set timeout 5
                expect {
                    -nocase "password" { send "$env(GHOSTTY_IDENTITY_PASSWORD)\\r" }
                    timeout {}
                    eof {}
                }
            """
            // exec sudo：登录 shell 被 sudo 进程替换，目标用户 exit 时没有可退回的父 shell，
            // SSH 会话随之结束（回到“按任意键重连”），而不是退回登录用户的 shell。
            identitySnippet = """
                # 用户身份：等待远端 shell 就绪标记，随后自动 sudo su 到目标用户
                set identity_ready 0
                set timeout 60
                expect {
                    "\(marker)" { set identity_ready 1 }
                    timeout {}
                    eof {}
                }
                if {$identity_ready} {
                    send "exec sudo -k su - \(identity.username.tclEscaped)\\r"
                \(hasIdentityPassword ? passwordSnippet : "")
                }
                set timeout 15
            """
            cfg.environmentVariables["GHOSTTY_IDENTITY_PASSWORD"] = identity.sudoPassword ?? ""
        }

        // 密码通过 SSH_ASKPASS 助手提供给 ssh，而不是用 expect 匹配 "password:" 提示：
        // 当服务器同时接受本地密钥时，密钥认证先行成功，根本不会出现密码提示，
        // expect 会空等整个 timeout（15 秒），表现为"连接很慢"。
        // askpass 方式下密钥/密码两种认证路径都无需等待。
        let useAskpass = conn.authMode == .password && !conn.password.isEmpty
        if useAskpass {
            let askpassURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty_ssh_askpass.sh")
            let askpassScript = """
            #!/bin/bash
            printf '%s\\n' "$GHOSTTY_ASKPASS_PASSWORD"
            """
            try? askpassScript.write(to: askpassURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: askpassURL.path)
            cfg.environmentVariables["SSH_ASKPASS"] = askpassURL.path
            cfg.environmentVariables["SSH_ASKPASS_REQUIRE"] = "force"
            cfg.environmentVariables["GHOSTTY_ASKPASS_PASSWORD"] = conn.password
        }

        // 用 expect 包装，实现断线后按任意键重连。
        // log_user 0 只包住 spawn 一行，隐藏 spawn 命令回显（身份切换模式下命令里
        // 含有远端引导命令，不应展示）；随后立即恢复输出，SSH 横幅、首次连接的
        // 主机密钥确认提示等均保持可见。
        var expectScript = useAskpass ? "set timeout 15\n" : ""
        // 核心（termio/Exec.zig）会用 surface 配置里的 term 无条件覆盖 PTY 环境
        // 变量的 TERM，apprt 侧设置的 TERM 不会生效；因此在 expect 脚本内显式
        // set env(TERM)，保证 ssh 子进程一定把设置窗口配置的 term 发送给远端。
        expectScript += syncPtyProc + "\n"
        expectScript += """
        trap {} SIGTERM
        trap {} SIGINT
        set env(TERM) "\(term.tclEscaped)"
        while {1} {

        """
        expectScript += "    log_user 0\n"
        expectScript += "    \(spawnLine)\n"
        expectScript += "    log_user 1\n"
        expectScript += """
            catch { unset synced_rows synced_cols }
            sync_ssh_pty
            trap { schedule_sync_ssh_pty } SIGWINCH

        """
        if !identitySnippet.isEmpty {
            expectScript += identitySnippet + "\n"
        }
        expectScript += """
            interact
            puts ""
            puts "\(reconnectPrompt)"
            expect_user -re . {}
        }
        """

        do {
            try expectScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            cfg.command = "/usr/bin/expect \(scriptURL.path)"
        } catch {
            // 写入失败时回退到普通 ssh 命令
            cfg.command = conn.sshCommand
        }

        // 应用终端编码环境变量
        for (key, value) in conn.terminalEnvironment {
            cfg.environmentVariables[key] = value
        }

        // X11 转发需要本地 DISPLAY / XAUTHORITY / PATH 环境变量
        if conn.x11Forwarding {
            for (key, value) in SSHX11Environment.current {
                cfg.environmentVariables[key] = value
            }
        }

        return cfg
    }

    // MARK: - Telnet

    private static func makeTelnet(_ conn: SSHConnection) -> Ghostty.SurfaceConfiguration? {
        guard let telnetPath = resolveTelnetExecutable() else { return nil }

        var cfg = Ghostty.SurfaceConfiguration()
        let term = configuredTerm()
        cfg.environmentVariables["TERM"] = term
        let portArg = conn.port == 23 ? "" : " \(conn.port)"

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_telnet_\(conn.id.uuidString).exp")
        let user = conn.username.tclEscaped
        let pass = conn.password.tclEscaped
        let hasUser = !conn.username.isEmpty
        let hasPass = !conn.password.isEmpty

        let expectScript = """
        set timeout 10
        set env(TERM) "\(term.tclEscaped)"
        spawn \(telnetPath) \(conn.host)\(portArg)

        # 某些 Telnet 服务（如 Ubuntu 的 PAM）连接后会先出现一个假的 Password: 提示，
        # 直接回车即可跳过，随后才会出现真正的 login 提示。
        expect {
            -nocase "password:" { send "\\r" }
            timeout { }
            eof { exit }
        }

        \(hasUser ? """
        # 真正的用户名 / login 提示
        expect {
            -nocase "username:" { send "\(user)\\r" }
            -nocase "login:" { send "\(user)\\r" }
            -nocase "user:" { send "\(user)\\r" }
            timeout { }
            eof { exit }
        }
        sleep 0.1
        """ : "")

        # 真正的密码提示
        expect {
            -nocase "password:" {
                sleep 0.3
                \(hasPass ? "send \"\(pass)\\r\"" : "send \"\\r\"")
            }
            timeout { }
            eof { exit }
        }

        interact
        """

        do {
            try expectScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            cfg.command = "/usr/bin/expect \(scriptURL.path)"
        } catch {
            cfg.command = "\(telnetPath) \(conn.host)\(portArg)"
        }

        return cfg
    }

    /// 查找本机可用的 telnet 可执行文件路径。
    private static func resolveTelnetExecutable() -> String? {
        let candidates = [
            "/usr/bin/telnet",
            "/opt/homebrew/bin/telnet",
            "/usr/local/bin/telnet"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // 常见路径都没有时，尝试让 shell 通过 PATH 查找。
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-lc", "command -v telnet"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if task.terminationStatus == 0,
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // ignore
        }
        return nil
    }
}
