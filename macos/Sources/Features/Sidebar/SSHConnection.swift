import Foundation
import SwiftUI
import Combine

// MARK: - 认证方式

enum SSHAuthMode: String, Codable, CaseIterable {
    case manual = "manual"
    case credential = "credential"
}

// MARK: - 连接方式

enum SSHConnectionMethod: String, Codable, CaseIterable {
    case direct = "direct"
    case jumpHost = "jumpHost"
    case proxy = "proxy"
}

// MARK: - SSH 连接配置

struct SSHConnection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var groupID: UUID?

    /// 认证模式：手动输入 / 使用凭证
    var authMode: SSHAuthMode
    /// 手动输入时的密码
    var password: String
    /// 使用凭证模式时选中的凭证 ID
    var credentialID: UUID?

    /// 连接方式
    var connectionMethod: SSHConnectionMethod

    /// 备注
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String = "",
        groupID: UUID? = nil,
        authMode: SSHAuthMode = .manual,
        password: String = "",
        credentialID: UUID? = nil,
        connectionMethod: SSHConnectionMethod = .direct,
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
        self.credentialID = credentialID
        self.connectionMethod = connectionMethod
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
        self.authMode = try container.decodeIfPresent(SSHAuthMode.self, forKey: .authMode) ?? .manual
        self.password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        self.credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID)
        self.connectionMethod = try container.decodeIfPresent(SSHConnectionMethod.self, forKey: .connectionMethod) ?? .direct
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, groupID
        case authMode, password, credentialID, connectionMethod, notes
    }

    /// 生成 SSH 命令行参数字符串
    var sshCommand: String {
        var cmd = "ssh"
        if !username.isEmpty {
            cmd += " \(username)@\(host)"
        } else {
            cmd += " \(host)"
        }
        if port != 22 {
            cmd += " -p \(port)"
        }
        return cmd
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
