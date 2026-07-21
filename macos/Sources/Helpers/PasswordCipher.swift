import Foundation
import CryptoKit

/// SSH 密码的 AES 对称加密存储工具。
///
/// 使用 AES-256-GCM 加密密码；加密后的文本带 `enc:v1:` 前缀，
/// 用于与历史明文数据区分（无前缀即按明文处理）。
///
/// 密钥由内置常量派生（固定密钥）：重装应用、UserDefaults 被清、
/// 经 iCloud 同步到其他机器后，密钥始终一致，密文都能解开，
/// 不会再出现“密钥存储位置变化导致历史密文无法解密、界面上直接显示 enc:v1:...”的问题。
/// 注意这是防明文落盘的混淆级保护，并非高安全级别加密。
enum PasswordCipher {
    private static let prefix = "enc:v1:"
    private static let defaultsKey = "com.xjai.exghostty.password-cipher.aes-key"
    private static let defaults = UserDefaults.standard

    /// 固定密钥，由内置常量经 SHA-256 派生，所有机器/安装保持一致。
    private static let fixedKey: SymmetricKey = {
        let digest = SHA256.hash(data: Data("com.xjai.exghostty.password-cipher.static-v1".utf8))
        return SymmetricKey(data: digest)
    }()

    /// 加密明文密码；空字符串或已带加密前缀的输入原样返回。
    static func encrypt(_ plaintext: String) -> String {
        guard !plaintext.isEmpty else { return plaintext }
        guard !plaintext.hasPrefix(prefix) else { return plaintext }

        do {
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: fixedKey)
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

        let body = String(stored.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: body) else { return stored }

        // 先试固定密钥，再试 UserDefaults 中的旧随机密钥（仅用于解开存量数据，不再写入）。
        var keys = [fixedKey]
        if let legacy = defaults.object(forKey: defaultsKey) as? Data {
            keys.append(SymmetricKey(data: legacy))
        }
        for key in keys {
            guard let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: key),
                  let text = String(data: plain, encoding: .utf8) else { continue }
            return text
        }
        return stored
    }
}
