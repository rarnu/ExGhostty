//
//  SSHConnectionConfig.swift
//  ExGhostty_iPad
//
//  Model for a saved SSH connection. Passwords are stored separately in Keychain.
//

import Foundation

enum ConnectionEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case gbk = "GBK"
    case gb2312 = "GB2312"
    case big5 = "Big5"
    case eucJP = "EUC-JP"
    case shiftJIS = "Shift_JIS"
    case latin1 = "ISO-8859-1"

    var id: String { rawValue }

    /// LANG environment value sent to the remote shell.
    var langEnvironment: String {
        switch self {
        case .utf8: return "en_US.UTF-8"
        case .gbk: return "zh_CN.GBK"
        case .gb2312: return "zh_CN.GB2312"
        case .big5: return "zh_TW.Big5"
        case .eucJP: return "ja_JP.EUC-JP"
        case .shiftJIS: return "ja_JP.SHIFT_JIS"
        case .latin1: return "en_US.ISO-8859-1"
        }
    }
}

enum SSHAuthMode: String, Codable, CaseIterable, Identifiable {
    case password
    case key

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return "密码"
        case .key: return "密钥"
        }
    }
}

struct SSHConnectionConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var authMode: SSHAuthMode = .password
    /// References SSHKeyStore entry when authMode == .key.
    var keyID: UUID? = nil
    /// Jump host: id of another saved connection used as bastion (ssh -J).
    var jumpHostID: UUID? = nil
    /// Group name for list sectioning; empty = ungrouped.
    var group: String = ""
    var encoding: ConnectionEncoding = .utf8
    var notes: String = ""

    /// User Identity: after login, automatically `sudo su` to this target
    /// user; the terminal and all remote operations (SFTP, Docker, System
    /// Monitor, ...) then run as that user.
    var identitySwitchEnabled: Bool = false
    /// Target username to switch to.
    var identityUsername: String = ""

    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    /// The effective identity; nil when disabled, the username is empty, or
    /// it matches the login user. The sudo password lives in Keychain.
    var effectiveIdentity: SSHIdentity.Identity? {
        guard identitySwitchEnabled, !identityUsername.isEmpty, identityUsername != username else { return nil }
        let password = KeychainHelper.identityPassword(for: id)
        return SSHIdentity.Identity(
            username: identityUsername,
            sudoPassword: (password?.isEmpty == false) ? password : nil
        )
    }

    /// The username effective remote operations run as: the switched user
    /// when an identity applies, otherwise the login user. Pure (no Keychain
    /// access) so it stays unit-testable; use it instead of reading
    /// `effectiveIdentity?.username ?? username` by hand.
    var effectiveUsername: String {
        if identitySwitchEnabled, !identityUsername.isEmpty, identityUsername != username {
            return identityUsername
        }
        return username
    }
}

// Custom Codable: new fields must decode from older saved JSON that lacks
// them, so every key is decoded with decodeIfPresent + a default. Kept in an
// extension to preserve the memberwise initializer.
extension SSHConnectionConfig {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMode, keyID, jumpHostID, group, encoding, notes
        case identitySwitchEnabled, identityUsername
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMode = try container.decodeIfPresent(SSHAuthMode.self, forKey: .authMode) ?? .password
        keyID = try container.decodeIfPresent(UUID.self, forKey: .keyID)
        jumpHostID = try container.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        encoding = try container.decodeIfPresent(ConnectionEncoding.self, forKey: .encoding) ?? .utf8
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        identitySwitchEnabled = try container.decodeIfPresent(Bool.self, forKey: .identitySwitchEnabled) ?? false
        identityUsername = try container.decodeIfPresent(String.self, forKey: .identityUsername) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMode, forKey: .authMode)
        try container.encodeIfPresent(keyID, forKey: .keyID)
        try container.encodeIfPresent(jumpHostID, forKey: .jumpHostID)
        try container.encode(group, forKey: .group)
        try container.encode(encoding, forKey: .encoding)
        try container.encode(notes, forKey: .notes)
        try container.encode(identitySwitchEnabled, forKey: .identitySwitchEnabled)
        try container.encode(identityUsername, forKey: .identityUsername)
    }
}
