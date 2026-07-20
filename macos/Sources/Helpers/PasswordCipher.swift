import Foundation
import CryptoKit

/// SSH 密码的 AES 对称加密存储工具。
///
/// 使用 AES-256-GCM 加密密码；密钥在首次使用时随机生成并保存在 UserDefaults 中，
/// 避免每次启动都弹出系统 Keychain 授权对话框。
/// 加密后的文本带 `enc:v1:` 前缀，用于与历史明文数据区分（无前缀即按明文处理）。
enum PasswordCipher {
    private static let prefix = "enc:v1:"
    private static let defaultsKey = "com.mitchellh.ghostty.password-cipher.aes-key"
    private static let defaults = UserDefaults.standard

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

    // MARK: - Key Storage

    private static func loadOrCreateKey() throws -> SymmetricKey {
        if let data = defaults.object(forKey: defaultsKey) as? Data {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        defaults.set(data, forKey: defaultsKey)
        return key
    }
}
