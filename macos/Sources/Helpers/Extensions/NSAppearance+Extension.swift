import Cocoa

extension NSAppearance {
    /// Returns true if the appearance is some kind of dark.
    var isDark: Bool {
        return name.rawValue.lowercased().contains("dark")
    }

    /// Initialize a desired NSAppearance for the Ghostty configuration.
    /// 当前固定为深色模式，用户无法在配置中修改。
    convenience init?(ghosttyConfig config: Ghostty.Config) {
        self.init(named: .darkAqua)
    }
}
