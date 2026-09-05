import AppKit
import SwiftUI

// MARK: - 开关

/// 「应用外观跟随终端主题」开关（设置-外观）。
/// 存在 UserDefaults（libghostty 不认识该键），默认开启。
enum SettingsAppTheme {
    static let followsTerminalKey = "app-theme-follows-terminal"

    static var followsTerminal: Bool {
        UserDefaults.ghostty.object(forKey: followsTerminalKey) as? Bool ?? true
    }
}

// MARK: - AppTheme

/// 应用级主题：把终端主题（背景/前景/调色板）扩散到整个 App UI。
///
/// 通过 `AppThemeStore.shared.current` 获取当前值；SwiftUI 视图用
/// `@Environment(\.appTheme)` 读取（根视图用 `ThemedRoot` 包裹即可自动更新）。
/// 开关关闭时所有颜色回退为系统外观。
struct AppTheme {
    /// 是否为浅色主题（按背景色明度判断）
    let isLight: Bool
    /// 是否跟随终端主题（false 表示系统外观）
    let followsTerminal: Bool

    /// 区域背景（终端背景 × background-opacity）
    let background: Color
    /// 侧边栏背景（比主背景稍深）
    let sidebarBackground: Color
    /// 主要文字颜色（终端前景）
    let foreground: Color
    /// 次要文字颜色（替代 .secondary）
    let secondaryForeground: Color
    /// 更弱的提示文字颜色
    let tertiaryForeground: Color
    /// 控件/卡片底色（搜索框、表单分组等，替代 controlBackgroundColor）
    let controlBackground: Color
    /// 强调色（终端调色板蓝）
    let accent: Color
    /// 选中背景（Tab/列表选中）
    let selectionBackground: Color

    // MARK: AppKit 版本

    var backgroundNS: NSColor { NSColor(background) }
    var sidebarBackgroundNS: NSColor { NSColor(sidebarBackground) }
    var foregroundNS: NSColor { NSColor(foreground) }
    var accentNS: NSColor { NSColor(accent) }

    /// 窗口 NSAppearance（影响按钮、输入框、菜单等系统控件的渲染）。
    /// 跟随终端主题时按背景明暗选择；否则维持现状固定深色。
    var windowAppearance: NSAppearance {
        if followsTerminal {
            return NSAppearance(named: isLight ? .aqua : .darkAqua)!
        }
        return NSAppearance(named: .darkAqua)!
    }
}

extension AppTheme {
    /// 系统外观（开关关闭时使用）。
    static var system: AppTheme {
        AppTheme(
            isLight: false,
            followsTerminal: false,
            background: Color(nsColor: .windowBackgroundColor),
            sidebarBackground: Color(nsColor: .controlBackgroundColor),
            foreground: Color(nsColor: .labelColor),
            secondaryForeground: Color(nsColor: .secondaryLabelColor),
            tertiaryForeground: Color(nsColor: .tertiaryLabelColor),
            controlBackground: Color(nsColor: .controlBackgroundColor),
            accent: Color(nsColor: .controlAccentColor),
            selectionBackground: Color(nsColor: .selectedContentBackgroundColor)
        )
    }

    /// 从终端配置派生（背景/前景/palette 均为主题解析后的最终值）。
    static func terminal(_ config: Ghostty.Config) -> AppTheme {
        let backgroundOpaque = NSColor(config.backgroundColor)
        let isLight = backgroundOpaque.isLightColor
        let background = backgroundOpaque.withAlphaComponent(config.backgroundOpacity)

        let accent: Color = config.paletteColor(4) ?? Color(nsColor: .controlAccentColor)

        return AppTheme(
            isLight: isLight,
            followsTerminal: true,
            background: Color(nsColor: background),
            sidebarBackground: Color(nsColor: background.shadow(withLevel: 0.08) ?? background),
            foreground: config.foregroundColor,
            secondaryForeground: config.foregroundColor.opacity(0.6),
            tertiaryForeground: config.foregroundColor.opacity(0.35),
            // 控件底色：深色主题叠一点白，浅色主题叠一点黑。
            controlBackground: Color(nsColor: backgroundOpaque.blended(
                withFraction: isLight ? 0.05 : 0.1,
                of: isLight ? .black : .white
            ) ?? backgroundOpaque),
            accent: accent,
            selectionBackground: accent.opacity(0.3)
        )
    }
}

// MARK: - Store

/// 持有当前 AppTheme 并随配置变化自动更新。
///
/// 配置变更经由 `.ghosttyConfigDidChange` 通知到达（设置保存时会触发
/// `ghostty.reloadConfig()`，因此开关切换也走这条链路即时生效）。
final class AppThemeStore: ObservableObject {
    static let shared = AppThemeStore()

    @Published private(set) var current: AppTheme

    private init() {
        current = Self.resolve()
        NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    func reload() {
        current = Self.resolve()
    }

    private static func resolve() -> AppTheme {
        guard SettingsAppTheme.followsTerminal,
              let appDelegate = NSApp.delegate as? AppDelegate else {
            return .system
        }
        let config = appDelegate.ghostty.config
        guard config.config != nil else { return .system }
        return .terminal(config)
    }
}

// MARK: - SwiftUI 环境

private struct AppThemeEnvironmentKey: EnvironmentKey {
    static var defaultValue: AppTheme { AppThemeStore.shared.current }
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeEnvironmentKey.self] }
        set { self[AppThemeEnvironmentKey.self] = newValue }
    }
}

/// 包裹根视图：把当前 AppTheme 注入环境，并随 AppThemeStore 自动更新。
struct ThemedRoot<Content: View>: View {
    @ObservedObject private var store = AppThemeStore.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.appTheme, store.current)
    }
}
