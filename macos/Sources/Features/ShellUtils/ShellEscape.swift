import Foundation

extension String {
    /// 单引号风格 Shell 参数转义，适合拼接进 shell 命令。
    ///
    /// 例如 `"it's"` → `"'it'\"'\"'s'"`。
    func singleQuotedShellArgument() -> String {
        "'" + self.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// 双引号风格 Shell 参数转义，保留原始内容中的双引号。
    ///
    /// 例如 `"my\"file"` → `"my\\\"file"`。
    func doubleQuotedShellArgument() -> String {
        "\"" + self.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
