import Foundation
import SwiftUI
import Combine

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
        notes: String = ""
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, groupID
        case authMode, password, keyPath, connectionMethod, jumpHostID, notes
    }

    /// 生成 SSH 命令行参数字符串（不含 "ssh" 前缀）
    var sshBaseArgs: String {
        var args = ""

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

        let userPrefix = username.isEmpty ? "" : "\(username)@"
        args += "\(userPrefix)\(host)"

        if port != 22 {
            args += " -p \(port)"
        }
        return args
    }

    /// 生成完整 SSH 命令行字符串
    var sshCommand: String {
        "ssh \(sshBaseArgs)"
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
