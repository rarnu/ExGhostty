import Foundation
import CryptoKit
import Security

/// SSH 密码的 AES 对称加密存储工具。
///
/// 使用 AES-256-GCM 加密密码；密钥在首次使用时随机生成并保存在 macOS Keychain 中。
/// 加密后的文本带 `enc:v1:` 前缀，用于与历史明文数据区分（无前缀即按明文处理）。
enum PasswordCipher {
    private static let prefix = "enc:v1:"
    private static let keychainService = "com.mitchellh.ghostty.password-cipher"
    private static let keychainAccount = "ssh-password-aes-key"

    /// 加密明文密码；空字符串或已带加密前缀的输入原样返回。
    static func encrypt(_ plaintext: String) -> String {
        guard !plaintext.isEmpty else { return plaintext }
        guard !plaintext.hasPrefix(prefix) else { return plaintext }

        do {
            let key = try loadOrCreateKey()
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
            guard let combined = sealed.combined else { return plaintext }
            return prefix + combined.base64EncodedString()
        } catch {
            // 加密失败时退化为明文，避免数据丢失。
            return plaintext
        }
    }

    /// 解密存储的密码；没有加密前缀的按明文（历史数据）直接返回。
    static func decrypt(_ stored: String) -> String {
        guard stored.hasPrefix(prefix) else { return stored }

        do {
            let key = try loadOrCreateKey()
            let body = String(stored.dropFirst(prefix.count))
            guard let data = Data(base64Encoded: body) else { return stored }
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: key)
            return String(data: plain, encoding: .utf8) ?? stored
        } catch {
            return stored
        }
    }

    // MARK: - Keychain

    private static func loadOrCreateKey() throws -> SymmetricKey {
        if let data = try readKeyFromKeychain() {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try storeKeyInKeychain(data)
        return key
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func readKeyFromKeychain() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return item as? Data
    }

    private static func storeKeyInKeychain(_ data: Data) throws {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        // 并发场景下可能已被其他调用写入，视为成功。
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
