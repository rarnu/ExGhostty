import Foundation
import SwiftUI
import Combine
import GhosttyKit

// MARK: - 认证方式

enum SSHAuthMode: String, Codable, CaseIterable {
    case password = "password"
    case key = "key"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "manual", "password":
            self = .password
        case "credential", "key":
            self = .key
        default:
            self = .password
        }
    }
}

// MARK: - 连接方式

enum SSHConnectionMethod: String, Codable, CaseIterable {
    case direct = "direct"
    case jumpHost = "jumpHost"
}

// MARK: - 终端编码选项

enum SSHTerminalEncoding: String, Codable, CaseIterable {
    case utf8 = "en_US.UTF-8"
    case gbk = "zh_CN.GBK"
    case gb2312 = "zh_CN.GB2312"
    case big5 = "zh_TW.Big5"
    case eucJP = "ja_JP.eucJP"
    case shiftJIS = "ja_JP.SJIS"
    case iso8859_1 = "en_US.ISO-8859-1"

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .gbk: return "GBK"
        case .gb2312: return "GB2312"
        case .big5: return "Big5"
        case .eucJP: return "EUC-JP"
        case .shiftJIS: return "Shift_JIS"
        case .iso8859_1: return "ISO-8859-1"
        }
    }
}

// MARK: - SSH 连接配置

struct SSHConnection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var groupID: UUID?

    /// 认证模式：密码登录 / 密钥登录
    var authMode: SSHAuthMode
    /// 密码登录时的密码
    var password: String
    /// 密钥登录时的密钥文件路径
    var keyPath: String?

    /// 连接方式
    var connectionMethod: SSHConnectionMethod
    /// SSH 跳板主机 ID（仅 connectionMethod == .jumpHost 时有效）
    var jumpHostID: UUID?

    /// 备注
    var notes: String

    /// 连接超时（毫秒）
    var timeoutMs: UInt32
    /// 心跳间隔（毫秒），0 表示不发送心跳
    var heartbeatMs: UInt32
    /// 终端显示编码（locale 字符串，如 en_US.UTF-8）
    var encoding: String
    /// 是否启用 X11 转发
    var x11Forwarding: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String = "",
        groupID: UUID? = nil,
        authMode: SSHAuthMode = .password,
        password: String = "",
        keyPath: String? = nil,
        connectionMethod: SSHConnectionMethod = .direct,
        jumpHostID: UUID? = nil,
        notes: String = "",
        timeoutMs: UInt32 = 30000,
        heartbeatMs: UInt32 = 30000,
        encoding: String = SSHTerminalEncoding.utf8.rawValue,
        x11Forwarding: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.groupID = groupID
        self.authMode = authMode
        self.password = password
        self.keyPath = keyPath
        self.connectionMethod = connectionMethod
        self.jumpHostID = jumpHostID
        self.notes = notes
        self.timeoutMs = timeoutMs
        self.heartbeatMs = heartbeatMs
        self.encoding = encoding
        self.x11Forwarding = x11Forwarding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 22
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        self.groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        self.authMode = try container.decodeIfPresent(SSHAuthMode.self, forKey: .authMode) ?? .password
        self.password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.keyPath = try container.decodeIfPresent(String.self, forKey: .keyPath)
        self.connectionMethod = {
            let raw = (try? container.decodeIfPresent(String.self, forKey: .connectionMethod)) ?? nil
            return SSHConnectionMethod(rawValue: raw ?? "") ?? .direct
        }()
        self.jumpHostID = try container.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.timeoutMs = try container.decodeIfPresent(UInt32.self, forKey: .timeoutMs) ?? 30000
        self.heartbeatMs = try container.decodeIfPresent(UInt32.self, forKey: .heartbeatMs) ?? 30000
        self.encoding = try container.decodeIfPresent(String.self, forKey: .encoding) ?? SSHTerminalEncoding.utf8.rawValue
        self.x11Forwarding = try container.decodeIfPresent(Bool.self, forKey: .x11Forwarding) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, groupID
        case authMode, password, keyPath, connectionMethod, jumpHostID, notes
        case timeoutMs, heartbeatMs, encoding, x11Forwarding
    }

    /// 生成用于 Ghostty 终端的 SurfaceConfiguration，包含 expect 包装、自动登录、断线重连。
    func makeGhosttySurfaceConfiguration() -> Ghostty.SurfaceConfiguration {
        var cfg = Ghostty.SurfaceConfiguration()

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_\(id.uuidString).exp")
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_ssh_\(id.uuidString).log")
        let logPath = logURL.path

        let expectScript: String
        if authMode == .password, !password.isEmpty {
            expectScript = """
            set timeout 15
            set password $env(SSHPASS)
            set logfile [open "\(logPath)" "a"]
            proc sshlog {msg} {
                global logfile
                puts $logfile "[clock format [clock seconds]] \\(msg)"
                flush $logfile
            }
            trap { sshlog "SIGTERM ignored" } SIGTERM
            trap { sshlog "SIGINT ignored" } SIGINT
            while {1} {
                sshlog "spawn ssh"
                log_user 0
                spawn /usr/bin/ssh \(sshBaseArgs)
                expect {
                    -nocase "password:" { send "$password\\r" }
                    timeout { sshlog "password timeout" }
                    eof { sshlog "ssh eof" }
                }
                log_user 1
                interact
                sshlog "interact returned"
                puts ""
                puts "按任意键进行重连"
                expect_user -re . {}
                sshlog "reconnect key pressed"
            }
            """
            cfg.environmentVariables["SSHPASS"] = password
        } else {
            expectScript = """
            set logfile [open "\(logPath)" "a"]
            proc sshlog {msg} {
                global logfile
                puts $logfile "[clock format [clock seconds]] \\(msg)"
                flush $logfile
            }
            trap { sshlog "SIGTERM ignored" } SIGTERM
            trap { sshlog "SIGINT ignored" } SIGINT
            while {1} {
                sshlog "spawn ssh"
                log_user 0
                spawn /usr/bin/ssh \(sshBaseArgs)
                log_user 1
                interact
                sshlog "interact returned"
                puts ""
                puts "按任意键进行重连"
                expect_user -re . {}
                sshlog "reconnect key pressed"
            }
            """
        }

        do {
            try expectScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            cfg.command = "/usr/bin/expect \(scriptURL.path)"
        } catch {
            cfg.command = sshCommand
        }

        for (key, value) in terminalEnvironment {
            cfg.environmentVariables[key] = value
        }

        if x11Forwarding {
            for (key, value) in SSHX11Environment.current {
                cfg.environmentVariables[key] = value
            }
        }

        return cfg
    }

    /// 生成 SSH 选项参数字符串（不含主机名，用于 rsync 等需要自行指定主机的场景）。
    var sshOptions: String {
        var args = ""

        // 连接超时（秒，支持小数）
        let timeoutSec = max(1, Double(timeoutMs) / 1000.0)
        args += "-o ConnectTimeout=\(timeoutSec) "

        // 心跳保活（秒，取整至少 1 秒）
        if heartbeatMs > 0 {
            let heartbeatSec = max(1, Int(heartbeatMs / 1000))
            args += "-o ServerAliveInterval=\(heartbeatSec) -o ServerAliveCountMax=10 "
        }

        // X11 转发（macOS 上 XQuartz 对 -Y 信任模式兼容更好）
        if x11Forwarding {
            args += "-Y "
        }

        if connectionMethod == .jumpHost,
           let jumpHostID,
           let jump = SSHStore.shared.connections.first(where: { $0.id == jumpHostID }) {
            let jumpUser = jump.username.isEmpty ? "" : "\(jump.username)@"
            let jumpPort = jump.port == 22 ? "" : ":\(jump.port)"
            args += "-J \(jumpUser)\(jump.host)\(jumpPort) "
        }

        if let keyPath, !keyPath.isEmpty {
            args += "-i \(keyPath) "
        }

        if port != 22 {
            args += "-p \(port) "
        }
        return args
    }

    /// 生成 SSH 命令行参数字符串（不含 "ssh" 前缀）
    var sshBaseArgs: String {
        let userPrefix = username.isEmpty ? "" : "\(username)@"
        return sshOptions + "\(userPrefix)\(host)"
    }

    /// 生成完整 SSH 命令行字符串
    var sshCommand: String {
        "ssh \(sshBaseArgs)"
    }

    /// 终端环境变量（编码相关）
    var terminalEnvironment: [String: String] {
        [
            "LANG": encoding,
            "LC_ALL": encoding,
        ]
    }
}

// MARK: - SSH 连接分组

struct SSHGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - 端口转发

/// 端口转发类型
enum PortForwardType: String, Codable, CaseIterable, Identifiable {
    case local = "local"
    case remote = "remote"
    case dynamic = "dynamic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "本地转发 (-L)"
        case .remote: return "远程转发 (-R)"
        case .dynamic: return "动态转发 (-D)"
        }
    }

    var description: String {
        switch self {
        case .local:
            return "将 SSH 主机可达的远端服务映射到本机端口"
        case .remote:
            return "将本机服务暴露给 SSH 主机，使其可通过远端端口访问"
        case .dynamic:
            return "在本机监听 HTTP/SOCKS 代理端口，并通过 SSH 主机访问目标地址"
        }
    }
}

/// 动态转发代理协议
enum PortForwardDynamicProtocol: String, Codable, CaseIterable, Identifiable {
    case socks5 = "socks5"

    var id: String { rawValue }
    var displayName: String { "SOCKS5" }
}

/// 端口转发规则
struct PortForwardRule: Identifiable, Codable {
    let id: UUID
    var name: String
    var type: PortForwardType
    /// 关联的 SSH 连接 ID
    var sshConnectionID: UUID?

    // 本地监听地址（本地转发 / 动态转发）
    var localListenHost: String
    var localListenPort: UInt16

    // 远端目标（本地转发 / 远程转发）
    var remoteHost: String
    var remotePort: UInt16

    // 远程转发专用：本机服务端口
    var localServicePort: UInt16

    // 动态转发专用：代理协议
    var dynamicProtocol: PortForwardDynamicProtocol

    /// 运行状态（不持久化）
    var isRunning: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        type: PortForwardType = .local,
        sshConnectionID: UUID? = nil,
        localListenHost: String = "127.0.0.1",
        localListenPort: UInt16 = 0,
        remoteHost: String = "localhost",
        remotePort: UInt16 = 0,
        localServicePort: UInt16 = 0,
        dynamicProtocol: PortForwardDynamicProtocol = .socks5
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.sshConnectionID = sshConnectionID
        self.localListenHost = localListenHost
        self.localListenPort = localListenPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.localServicePort = localServicePort
        self.dynamicProtocol = dynamicProtocol
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, sshConnectionID
        case localListenHost, localListenPort
        case remoteHost, remotePort
        case localServicePort
        case dynamicProtocol
    }

    /// 格式化摘要，显示在列表中
    func summaryText(using connection: SSHConnection?) -> String {
        let connHost = connection?.name ?? connection?.host ?? "未知主机"
        switch type {
        case .local:
            return "\(localListenHost):\(localListenPort) → \(connHost) → \(remoteHost):\(remotePort)"
        case .remote:
            return "\(connHost):\(remotePort) → localhost:\(localServicePort)"
        case .dynamic:
            return "\(localListenHost):\(localListenPort) (\(dynamicProtocol.displayName))"
        }
    }

    /// 是否为有效规则（仅做基础校验）
    var isValid: Bool {
        guard sshConnectionID != nil else { return false }
        switch type {
        case .local:
            return localListenPort > 0 && remotePort > 0 && !remoteHost.isEmpty
        case .remote:
            return remotePort > 0 && localServicePort > 0
        case .dynamic:
            return localListenPort > 0
        }
    }
}
