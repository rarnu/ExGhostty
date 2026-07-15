import Foundation

extension String {
    /// 去掉 ANSI 转义序列（如 `\x1B[32;1m...\x1B[m`）。
    func strippingANSISequences() -> String {
        let pattern = "\\x1B\\[[0-9;]*m"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let range = NSRange(self.startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")
    }
}
