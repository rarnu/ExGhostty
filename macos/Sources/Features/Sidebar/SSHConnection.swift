import Foundation
import SwiftUI
import Combine

/// 一个 SSH 连接配置
struct SSHConnection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var groupID: UUID?
    var authType: SSHAuthType

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String = "",
        groupID: UUID? = nil,
        authType: SSHAuthType = .password
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.groupID = groupID
        self.authType = authType
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

/// 认证类型
enum SSHAuthType: String, Codable, CaseIterable {
    case password
    case key
    case agent
}

/// SSH 连接分组
struct SSHGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
