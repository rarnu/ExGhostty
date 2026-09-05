import Cocoa

extension NSAppearance {
    /// Returns true if the appearance is some kind of dark.
    var isDark: Bool {
        return name.rawValue.lowercased().contains("dark")
    }

    /// Initialize a desired NSAppearance for the Ghostty configuration.
    /// 「应用外观跟随终端主题」开启时按终端背景明暗选择外观；
    /// 关闭时维持固定深色模式。
    convenience init?(ghosttyConfig config: Ghostty.Config) {
        if SettingsAppTheme.followsTerminal {
            let background = NSColor(config.backgroundColor)
            self.init(named: background.isLightColor ? .aqua : .darkAqua)
        } else {
            self.init(named: .darkAqua)
        }
    }
}
