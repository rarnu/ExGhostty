import SwiftUI
import AppKit
import GhosttyKit
import UniformTypeIdentifiers

// MARK: - Window Controller

/// 非模态、置顶、与主窗口风格一致的设置窗口控制器。
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var configObserver: NSObjectProtocol?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func show(relativeTo parentWindow: NSWindow?, config: Ghostty.Config) {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        window?.close()

        let rect = NSRect(x: 0, y: 0, width: 820, height: 620)
        let panel = GhosttyPanelWindow(contentRect: rect, config: config)
        panel.title = "Settings".localized
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]

        let model = SettingsModel(config: config)
        let rootView = SettingsView(
            onSave: { [weak panel] in
                panel?.close()
            },
            onCancel: { [weak panel] in
                panel?.close()
            }
        )
        .environmentObject(model)

        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.configureBackgroundBlur(config: config, container: hosting)

        self.window = panel

        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window, let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return }
            (window as? GhosttyPanelWindow)?.applyBackground(config: config)
            window.backgroundColor = (window as? GhosttyPanelWindow)?.backgroundColor ?? window.backgroundColor
        }

        window?.centerRelative(to: parentWindow)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Config File Writer

/// 负责读取、修改并写回 Ghostty 配置文件，保留注释与空白行。
final class ConfigFileWriter {
    private var lines: [String]
    private var keyLineMap: [String: [Int]] = [:]
    let url: URL

    init(url: URL) {
        self.url = url
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            self.lines = content.components(separatedBy: .newlines)
        } else {
            self.lines = []
        }
        reindex()
    }

    private func parse(line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func reindex() {
        keyLineMap.removeAll()
        for (idx, line) in lines.enumerated() {
            guard let parsed = parse(line: line) else { continue }
            keyLineMap[parsed.key, default: []].append(idx)
        }
    }

    func firstValue(for key: String) -> String? {
        guard let idx = keyLineMap[key]?.first else { return nil }
        return parse(line: lines[idx])?.value
    }

    func values(for key: String) -> [String] {
        keyLineMap[key]?.compactMap { parse(line: lines[$0])?.value } ?? []
    }

    func setValue(_ value: String?, forKey key: String) {
        if let value {
            let line = "\(key) = \(escaped(value))"
            if let firstIdx = keyLineMap[key]?.first {
                lines[firstIdx] = line
                for other in (keyLineMap[key] ?? []).dropFirst().reversed() {
                    lines.remove(at: other)
                }
            } else {
                lines.append(line)
            }
        } else {
            removeKey(key)
        }
        reindex()
    }

    func removeKey(_ key: String) {
        for idx in (keyLineMap[key] ?? []).reversed() {
            lines.remove(at: idx)
        }
        reindex()
    }

    /// 更新受管 keybind 行，保留其他 keybind 不动。
    func setKeybinds(_ bindings: [String: String], managedActions: [String]) {
        let managed = Set(managedActions)
        var newLines: [String] = []
        for line in lines {
            guard let parsed = parse(line: line),
                  parsed.key == "keybind" else {
                newLines.append(line)
                continue
            }
            let parts = parsed.value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                newLines.append(line)
                continue
            }
            let action = String(parts[1])
            if managed.contains(action) {
                continue
            }
            newLines.append(line)
        }
        lines = newLines
        for (action, trigger) in bindings.sorted(by: { $0.key < $1.key }) where !trigger.isEmpty {
            lines.append("keybind = \(trigger)=\(action)")
        }
        reindex()
    }

    func write() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func escaped(_ value: String) -> String {
        if value.isEmpty || value.contains(" ") || value.contains("\t") || value.contains("#") {
            return "\"\(value)\""
        }
        return value
    }
}

// MARK: - Settings Model

@MainActor
final class SettingsModel: ObservableObject {
    static let managedKeybindActions: [String] = [
        "new_tab",
        "new_split:right",
        "new_split:down",
        "close_surface",
        "quit",
        "copy_to_clipboard",
        "paste_from_clipboard",
        "select_all",
        "previous_tab",
        "next_tab",
        "goto_split:left",
        "goto_split:right",
        "goto_split:up",
        "goto_split:down",
        "increase_font_size",
        "decrease_font_size",
        "reset_font_size",
        "toggle_fullscreen",
        "inspector",
    ]

    private let config: Ghostty.Config
    private let fileURL: URL?

    // General
    @Published var language: String = "en"

    // Appearance
    @Published var fontFamily: String = ""
    @Published var fontSize: Float = 15
    @Published var fontThicken: Bool = true
    @Published var backgroundColor: Color = Color(hex: "#282C34")
    @Published var foregroundColor: Color = Color.white
    @Published var backgroundOpacity: Double = 0.8
    @Published var backgroundBlur: Bool = true
    @Published var backgroundImage: String = ""
    @Published var backgroundImageOpacity: Double = 1.0
    @Published var backgroundImageFit: SettingsBackgroundImageFit = .contain
    @Published var useSelectionForeground: Bool = false
    @Published var selectionForeground: Color = Color.white
    @Published var useSelectionBackground: Bool = false
    @Published var selectionBackground: Color = Color.black
    @Published var useCursorColor: Bool = false
    @Published var cursorColor: Color = Color.white
    @Published var cursorOpacity: Double = 1.0
    @Published var cursorStyle: SettingsCursorStyle = .bar
    @Published var cursorBlink: Bool = false

    // Notification
    @Published var notifyOnCommandFinish: SettingsNotifyOnCommandFinish = .never
    @Published var notifyActionBell: Bool = true
    @Published var notifyActionNotify: Bool = false

    // Window
    @Published var scrollbackLimit: Int = 8_388_608
    @Published var scrollbar: SettingsScrollbar = .never
    @Published var maximize: Bool = false
    @Published var confirmCloseSurface: Bool = false

    // Directory
    @Published var windowInheritWorkingDirectory: Bool = true
    @Published var tabInheritWorkingDirectory: Bool = true
    @Published var splitInheritWorkingDirectory: Bool = true

    // Secure
    @Published var clipboardRead: SettingsClipboardAccess = .ask
    @Published var clipboardWrite: SettingsClipboardAccess = .ask
    @Published var clipboardTrimTrailingSpaces: Bool = true
    @Published var clipboardPasteProtection: Bool = true
    @Published var macosAutoSecureInput: Bool = true
    @Published var macosSecureInputIndication: Bool = true
    @Published var macosAppleScript: Bool = true
    @Published var macosShortcuts: SettingsMacShortcuts = .ask

    // Terminal
    @Published var term: String = "xterm-ghostty"
    @Published var asyncBackend: SettingsAsyncBackend = .auto

    // Keybind
    @Published var keybinds: [String: String] = [:]

    // AI (stored in UserDefaults because libghostty doesn't know these keys)
    @Published var aiEndpoint: String = ""
    @Published var aiApiKey: String = ""
    @Published var aiModel: String = ""

    init(config: Ghostty.Config) {
        self.config = config
        self.fileURL = (NSApp.delegate as? AppDelegate)?.ghostty.configFileURL
        load()
    }

    private func load() {
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        let preferredFont = "JetBrainsMono Nerd Font Mono"

        if let url = fileURL {
            let writer = ConfigFileWriter(url: url)

            language = writer.firstValue(for: "language") ?? "en"
            fontFamily = writer.firstValue(for: "font-family") ?? (families.contains(preferredFont) ? preferredFont : "")
            fontSize = Float(writer.firstValue(for: "font-size") ?? "") ?? 15
            fontThicken = parseBool(writer.firstValue(for: "font-thicken")) ?? true

            backgroundColor = writer.firstValue(for: "background").flatMap { Color(hex: $0) } ?? config.backgroundColor
            foregroundColor = writer.firstValue(for: "foreground").flatMap { Color(hex: $0) } ?? Color.white
            backgroundOpacity = writer.firstValue(for: "background-opacity").flatMap(Double.init) ?? config.backgroundOpacity
            backgroundBlur = parseBlur(writer.firstValue(for: "background-blur")) ?? config.backgroundBlur.isEnabled
            backgroundImage = writer.firstValue(for: "background-image") ?? ""
            backgroundImageOpacity = writer.firstValue(for: "background-image-opacity").flatMap(Double.init) ?? 1.0
            backgroundImageFit = writer.firstValue(for: "background-image-fit").flatMap(SettingsBackgroundImageFit.init(rawValue:)) ?? .contain

            if let sf = writer.firstValue(for: "selection-foreground").flatMap({ Color(hex: $0) }) {
                useSelectionForeground = true
                selectionForeground = sf
            }
            if let sb = writer.firstValue(for: "selection-background").flatMap({ Color(hex: $0) }) {
                useSelectionBackground = true
                selectionBackground = sb
            }
            if let cc = writer.firstValue(for: "cursor-color").flatMap({ Color(hex: $0) }) {
                useCursorColor = true
                cursorColor = cc
            }

            cursorOpacity = writer.firstValue(for: "cursor-opacity").flatMap(Double.init) ?? 1.0
            cursorStyle = writer.firstValue(for: "cursor-style").flatMap(SettingsCursorStyle.init(rawValue:)) ?? .bar
            cursorBlink = parseBool(writer.firstValue(for: "cursor-style-blink")) ?? false

            notifyOnCommandFinish = writer.firstValue(for: "notify-on-command-finish").flatMap(SettingsNotifyOnCommandFinish.init(rawValue:)) ?? SettingsNotifyOnCommandFinish(rawValue: config.notifyOnCommandFinish.rawValue) ?? .never

            let notifyActionRaw = writer.firstValue(for: "notify-on-command-finish-action") ?? ""
            notifyActionBell = notifyActionRaw.isEmpty ? config.notifyOnCommandFinishAction.contains(.bell) : notifyActionRaw.contains("bell") && !notifyActionRaw.contains("no-bell")
            notifyActionNotify = notifyActionRaw.isEmpty ? config.notifyOnCommandFinishAction.contains(.notify) : notifyActionRaw.contains("notify") && !notifyActionRaw.contains("no-notify")

            scrollbackLimit = writer.firstValue(for: "scrollback-limit").flatMap(Int.init) ?? 8_388_608
            scrollbar = writer.firstValue(for: "scrollbar").flatMap(SettingsScrollbar.init(rawValue:)) ?? SettingsScrollbar(rawValue: config.scrollbar.rawValue) ?? .never
            maximize = parseBool(writer.firstValue(for: "maximize")) ?? config.maximize
            confirmCloseSurface = parseConfirmClose(writer.firstValue(for: "confirm-close-surface")) ?? false

            windowInheritWorkingDirectory = parseBool(writer.firstValue(for: "window-inherit-working-directory")) ?? true
            tabInheritWorkingDirectory = parseBool(writer.firstValue(for: "tab-inherit-working-directory")) ?? true
            splitInheritWorkingDirectory = parseBool(writer.firstValue(for: "split-inherit-working-directory")) ?? true

            clipboardRead = writer.firstValue(for: "clipboard-read").flatMap(SettingsClipboardAccess.init(rawValue:)) ?? .ask
            clipboardWrite = writer.firstValue(for: "clipboard-write").flatMap(SettingsClipboardAccess.init(rawValue:)) ?? .ask
            clipboardTrimTrailingSpaces = parseBool(writer.firstValue(for: "clipboard-trim-trailing-spaces")) ?? true
            clipboardPasteProtection = parseBool(writer.firstValue(for: "clipboard-paste-protection")) ?? true
            macosAutoSecureInput = parseBool(writer.firstValue(for: "macos-auto-secure-input")) ?? true
            macosSecureInputIndication = parseBool(writer.firstValue(for: "macos-secure-input-indication")) ?? true
            macosAppleScript = parseBool(writer.firstValue(for: "macos-applescript")) ?? true
            macosShortcuts = writer.firstValue(for: "macos-shortcuts").flatMap(SettingsMacShortcuts.init(rawValue:)) ?? SettingsMacShortcuts(rawValue: config.macosShortcuts.rawValue) ?? .ask

            term = writer.firstValue(for: "term") ?? "xterm-ghostty"
            asyncBackend = writer.firstValue(for: "async-backend").flatMap(SettingsAsyncBackend.init(rawValue:)) ?? .auto

            var binds: [String: String] = [:]
            for value in writer.values(for: "keybind") {
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let action = String(parts[1])
                if SettingsModel.managedKeybindActions.contains(action) {
                    binds[action] = String(parts[0])
                }
            }
            keybinds = binds
        } else {
            // 没有配置文件路径时回退到当前运行时配置
            backgroundColor = config.backgroundColor
            backgroundOpacity = config.backgroundOpacity
            backgroundBlur = config.backgroundBlur.isEnabled
            fontFamily = families.contains(preferredFont) ? preferredFont : ""
        }

        let ud = UserDefaults.ghostty
        aiEndpoint = ud.string(forKey: "ai-endpoint") ?? ""
        aiApiKey = ud.string(forKey: "ai-apikey") ?? ""
        aiModel = ud.string(forKey: "ai-model") ?? ""
    }

    func save() {
        guard let url = fileURL else { return }
        let writer = ConfigFileWriter(url: url)

        writer.setValue(language == "en" ? nil : language, forKey: "language")
        writer.setValue(fontFamily.isEmpty ? nil : fontFamily, forKey: "font-family")
        writer.setValue(String(format: "%.0f", fontSize), forKey: "font-size")
        writer.setValue(fontThicken ? "true" : "false", forKey: "font-thicken")

        writer.setValue(backgroundColor.toHex(), forKey: "background")
        writer.setValue(foregroundColor.toHex(), forKey: "foreground")
        writer.setValue(String(format: "%.2f", backgroundOpacity), forKey: "background-opacity")
        writer.setValue(backgroundBlur ? "true" : "false", forKey: "background-blur")
        writer.setValue(backgroundImage.isEmpty ? nil : backgroundImage, forKey: "background-image")
        writer.setValue(String(format: "%.2f", backgroundImageOpacity), forKey: "background-image-opacity")
        writer.setValue(backgroundImageFit.rawValue, forKey: "background-image-fit")

        writer.setValue(useSelectionForeground ? selectionForeground.toHex() : nil, forKey: "selection-foreground")
        writer.setValue(useSelectionBackground ? selectionBackground.toHex() : nil, forKey: "selection-background")
        writer.setValue(useCursorColor ? cursorColor.toHex() : nil, forKey: "cursor-color")
        writer.setValue(String(format: "%.2f", cursorOpacity), forKey: "cursor-opacity")
        writer.setValue(cursorStyle.rawValue, forKey: "cursor-style")
        writer.setValue(cursorBlink ? "true" : "false", forKey: "cursor-style-blink")

        writer.setValue(notifyOnCommandFinish.rawValue, forKey: "notify-on-command-finish")
        var notifyActions: [String] = []
        if notifyActionBell { notifyActions.append("bell") } else { notifyActions.append("no-bell") }
        if notifyActionNotify { notifyActions.append("notify") } else { notifyActions.append("no-notify") }
        writer.setValue(notifyActions.joined(separator: ","), forKey: "notify-on-command-finish-action")

        writer.setValue(String(scrollbackLimit), forKey: "scrollback-limit")
        writer.setValue(scrollbar.rawValue, forKey: "scrollbar")
        writer.setValue(maximize ? "true" : "false", forKey: "maximize")
        writer.setValue(confirmCloseSurface ? "true" : "false", forKey: "confirm-close-surface")

        writer.setValue(windowInheritWorkingDirectory ? "true" : "false", forKey: "window-inherit-working-directory")
        writer.setValue(tabInheritWorkingDirectory ? "true" : "false", forKey: "tab-inherit-working-directory")
        writer.setValue(splitInheritWorkingDirectory ? "true" : "false", forKey: "split-inherit-working-directory")

        writer.setValue(clipboardRead.rawValue, forKey: "clipboard-read")
        writer.setValue(clipboardWrite.rawValue, forKey: "clipboard-write")
        writer.setValue(clipboardTrimTrailingSpaces ? "true" : "false", forKey: "clipboard-trim-trailing-spaces")
        writer.setValue(clipboardPasteProtection ? "true" : "false", forKey: "clipboard-paste-protection")
        writer.setValue(macosAutoSecureInput ? "true" : "false", forKey: "macos-auto-secure-input")
        writer.setValue(macosSecureInputIndication ? "true" : "false", forKey: "macos-secure-input-indication")
        writer.setValue(macosAppleScript ? "true" : "false", forKey: "macos-applescript")
        writer.setValue(macosShortcuts.rawValue, forKey: "macos-shortcuts")

        writer.setValue(term, forKey: "term")
        writer.setValue(asyncBackend.rawValue, forKey: "async-backend")

        writer.setKeybinds(keybinds, managedActions: SettingsModel.managedKeybindActions)

        try? writer.write()

        let ud = UserDefaults.ghostty
        ud.set(aiEndpoint, forKey: "ai-endpoint")
        ud.set(aiApiKey, forKey: "ai-apikey")
        ud.set(aiModel, forKey: "ai-model")

        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
    }
}

// MARK: - Enums

enum SettingsBackgroundImageFit: String, CaseIterable {
    case contain, cover, stretch, none
}

enum SettingsCursorStyle: String, CaseIterable {
    case bar, block, underline, block_hollow
}

enum SettingsNotifyOnCommandFinish: String, CaseIterable {
    case never, unfocused, always
}

enum SettingsScrollbar: String, CaseIterable {
    case system, never
}

enum SettingsClipboardAccess: String, CaseIterable {
    case allow, deny, ask
}

enum SettingsMacShortcuts: String, CaseIterable {
    case allow, deny, ask
}

enum SettingsAsyncBackend: String, CaseIterable {
    case auto, epoll, io_uring
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, notification, window, directory, secure, terminal, keybind, ai
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General".localized
        case .appearance: return "Appearance".localized
        case .notification: return "Notification".localized
        case .window: return "Window".localized
        case .directory: return "Directory".localized
        case .secure: return "Secure".localized
        case .terminal: return "Terminal".localized
        case .keybind: return "Keybind".localized
        case .ai: return "AI".localized
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .notification: return "bell.badge"
        case .window: return "macwindow"
        case .directory: return "folder"
        case .secure: return "lock.shield"
        case .terminal: return "terminal"
        case .keybind: return "keyboard"
        case .ai: return "cpu"
        }
    }
}

// MARK: - View

struct SettingsView: View {
    @EnvironmentObject private var model: SettingsModel

    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var selectedCategory: SettingsCategory? = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                categoryList
                    .frame(width: 180)

                Divider()

                ScrollView {
                    detailContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.clear)
            }

            Divider()

            bottomBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .background(Color.clear)
    }

    private var categoryList: some View {
        List(SettingsCategory.allCases, selection: $selectedCategory) { category in
            Label(category.title, systemImage: category.icon)
                .font(.system(size: 15))
                .frame(height: 38)
                .tag(category)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedCategory {
        case .general: generalSection
        case .appearance: appearanceSection
        case .notification: notificationSection
        case .window: windowSection
        case .directory: directorySection
        case .secure: secureSection
        case .terminal: terminalSection
        case .keybind: keybindSection
        case .ai: aiSection
        case .none: EmptyView()
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button("Cancel".localized) { onCancel() }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            Button("Save".localized) {
                model.save()
                onSave()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("General")

            settingsRow(label: "Language".localized) {
                Picker("", selection: $model.language) {
                    Text("English".localized).tag("en")
                    Text("简体中文".localized).tag("zh_CN")
                    Text("繁體中文".localized).tag("zh_TW")
                    Text("日本語".localized).tag("ja")
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            Text("Language changes will take effect after restarting Ghostty.".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Appearance")

            let families = NSFontManager.shared.availableFontFamilies.sorted()
            settingsRow(label: "Font Family".localized) {
                Picker("", selection: $model.fontFamily) {
                    Text("System Default".localized).tag("")
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260)
            }

            settingsRow(label: "Font Size".localized) {
                Picker("", selection: $model.fontSize) {
                    ForEach(Array(stride(from: 10, through: 30, by: 1)), id: \.self) { size in
                        Text("\(size)").tag(Float(size))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            settingsRow(label: "Font Thicken".localized) {
                Toggle("", isOn: $model.fontThicken)
                    .toggleStyle(.switch)
            }

            settingsRow(label: "Background".localized) {
                ColorPicker("", selection: $model.backgroundColor, supportsOpacity: false)
            }

            settingsRow(label: "Foreground".localized) {
                ColorPicker("", selection: $model.foregroundColor, supportsOpacity: false)
            }

            settingsRow(label: "Background Opacity".localized) {
                Slider(value: $model.backgroundOpacity, in: 0.1...1, step: 0.05)
                    .frame(width: 200)
                Text(String(format: "%.0f%%", model.backgroundOpacity * 100))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            settingsRow(label: "Background Blur".localized) {
                Toggle("", isOn: $model.backgroundBlur)
                    .toggleStyle(.switch)
            }

            settingsRow(label: "Background Image".localized) {
                HStack(spacing: 8) {
                    TextField("", text: $model.backgroundImage)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Button("Choose...".localized) {
                        chooseBackgroundImage()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            settingsRow(label: "Background Image Opacity".localized) {
                Slider(value: $model.backgroundImageOpacity, in: 0.1...1, step: 0.05)
                    .frame(width: 200)
                Text(String(format: "%.0f%%", model.backgroundImageOpacity * 100))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            settingsRow(label: "Background Fit".localized) {
                Picker("", selection: $model.backgroundImageFit) {
                    ForEach(SettingsBackgroundImageFit.allCases, id: \.self) { fit in
                        Text(fit.displayName).tag(fit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            optionalColorRow(label: "Selection Foreground".localized, use: $model.useSelectionForeground, color: $model.selectionForeground)
            optionalColorRow(label: "Selection Background".localized, use: $model.useSelectionBackground, color: $model.selectionBackground)
            optionalColorRow(label: "Cursor Color".localized, use: $model.useCursorColor, color: $model.cursorColor)

            settingsRow(label: "Cursor Opacity".localized) {
                Slider(value: $model.cursorOpacity, in: 0.1...1, step: 0.05)
                    .frame(width: 200)
                Text(String(format: "%.0f%%", model.cursorOpacity * 100))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            settingsRow(label: "Cursor Style".localized) {
                Picker("", selection: $model.cursorStyle) {
                    ForEach(SettingsCursorStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }

            settingsRow(label: "Cursor Blink".localized) {
                Toggle("", isOn: $model.cursorBlink)
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: Notification

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Notification")

            settingsRow(label: "Notify on Command Finish".localized) {
                Picker("", selection: $model.notifyOnCommandFinish) {
                    ForEach(SettingsNotifyOnCommandFinish.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Notify Action".localized)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 24) {
                    Toggle("Bell".localized, isOn: $model.notifyActionBell)
                    Toggle("Notify".localized, isOn: $model.notifyActionNotify)
                }
            }
        }
    }

    // MARK: Window

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Window")

            settingsRow(label: "Scrollback Limit".localized) {
                TextField("", value: $model.scrollbackLimit, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            settingsRow(label: "Scrollbar".localized) {
                Picker("", selection: $model.scrollbar) {
                    ForEach(SettingsScrollbar.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
            }

            settingsRow(label: "Maximize on Launch".localized) {
                Toggle("", isOn: $model.maximize)
                    .toggleStyle(.switch)
            }

            settingsRow(label: "Confirm Close".localized) {
                Toggle("", isOn: $model.confirmCloseSurface)
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: Directory

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Directory")

            Toggle("Window Inherit Working Directory".localized, isOn: $model.windowInheritWorkingDirectory)
            Toggle("Tab Inherit Working Directory".localized, isOn: $model.tabInheritWorkingDirectory)
            Toggle("Split Inherit Working Directory".localized, isOn: $model.splitInheritWorkingDirectory)
        }
    }

    // MARK: Secure

    private var secureSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Secure")

            settingsRow(label: "Clipboard Read".localized) {
                Picker("", selection: $model.clipboardRead) {
                    ForEach(SettingsClipboardAccess.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            settingsRow(label: "Clipboard Write".localized) {
                Picker("", selection: $model.clipboardWrite) {
                    ForEach(SettingsClipboardAccess.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Toggle("Clipboard Trim Trailing Spaces".localized, isOn: $model.clipboardTrimTrailingSpaces)
            Toggle("Clipboard Paste Protection".localized, isOn: $model.clipboardPasteProtection)
            Toggle("Auto Secure Input".localized, isOn: $model.macosAutoSecureInput)
            Toggle("Secure Input Indication".localized, isOn: $model.macosSecureInputIndication)
            Toggle("AppleScript".localized, isOn: $model.macosAppleScript)

            settingsRow(label: "Shortcuts".localized) {
                Picker("", selection: $model.macosShortcuts) {
                    ForEach(SettingsMacShortcuts.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
    }

    // MARK: Terminal

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Terminal")

            settingsRow(label: "Term".localized) {
                TextField("", text: $model.term)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            settingsRow(label: "Async Backend".localized) {
                Picker("", selection: $model.asyncBackend) {
                    ForEach(SettingsAsyncBackend.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
    }

    // MARK: Keybind

    @State private var capturingAction: String? = nil

    private var keybindSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Keybind")

            List {
                ForEach(SettingsModel.managedKeybindActions, id: \.self) { action in
                    HStack {
                        Text(keybindActionTitle(action))
                            .frame(width: 180, alignment: .leading)
                        Spacer()
                        if capturingAction == action {
                            ShortcutCaptureView { trigger in
                                if let trigger {
                                    model.keybinds[action] = trigger
                                }
                                capturingAction = nil
                            } onCancel: {
                                capturingAction = nil
                            }
                            .frame(width: 160, height: 24)
                        } else {
                            Text(model.keybinds[action] ?? "None".localized)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 160, alignment: .trailing)

                            Button("Edit".localized) {
                                capturingAction = action
                            }
                            .buttonStyle(.plain)

                            if model.keybinds[action] != nil {
                                Button {
                                    model.keybinds.removeValue(forKey: action)
                                } label: {
                                    Image(systemName: "xmark")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: AI

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("AI")

            settingsRow(label: "API Endpoint".localized) {
                TextField("", text: $model.aiEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }

            settingsRow(label: "API Key".localized) {
                SecureField("", text: $model.aiApiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }

            settingsRow(label: "Model".localized) {
                TextField("", text: $model.aiModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }
        }
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.localized)
            .font(.system(size: 18, weight: .semibold))
            .padding(.bottom, 4)
    }

    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 170, alignment: .leading)
            content()
            Spacer()
        }
    }

    private func optionalColorRow(label: String, use: Binding<Bool>, color: Binding<Color>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 170, alignment: .leading)
            Toggle("Use Default".localized, isOn: use)
            ColorPicker("", selection: color, supportsOpacity: false)
                .disabled(!use.wrappedValue)
            Spacer()
        }
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { result in
            if result == .OK, let url = panel.url {
                model.backgroundImage = url.path
            }
        }
    }

    private func keybindActionTitle(_ action: String) -> String {
        let formatted = action
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        let key = "Keybind: \(formatted.capitalized)"
        return key.localized
    }
}

// MARK: - Shortcut Capture View

struct ShortcutCaptureView: NSViewRepresentable {
    var onCapture: (String?) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        guard let trigger = ghosttyKeybindString(from: event) else {
            onCapture?(nil)
            return
        }
        onCapture?(trigger)
    }

    override func flagsChanged(with event: NSEvent) {
        // 只记录修饰键时不做任何事
    }

    private func ghosttyKeybindString(from event: NSEvent) -> String? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods != [] else { return nil }

        let keyName: String
        if let special = specialKeyName(keyCode: event.keyCode) {
            keyName = special
        } else if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            keyName = String(chars.prefix(1))
        } else {
            return nil
        }

        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.command) { parts.append("cmd") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    private func specialKeyName(keyCode: UInt16) -> String? {
        switch keyCode {
        case 126: return "up"
        case 125: return "down"
        case 123: return "left"
        case 124: return "right"
        case 53: return "escape"
        case 36, 76: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "backspace"
        case 117: return "delete"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        default: return nil
        }
    }
}

// MARK: - Helpers

private func parseBool(_ value: String?) -> Bool? {
    guard let value else { return nil }
    switch value.lowercased() {
    case "true", "yes", "1": return true
    case "false", "no", "0": return false
    default: return nil
    }
}

private func parseBlur(_ value: String?) -> Bool? {
    guard let value else { return nil }
    switch value.lowercased() {
    case "true", "yes", "1", "macos-glass-regular", "macos-glass-clear": return true
    case "false", "no", "0": return false
    default: return nil
    }
}

private func parseConfirmClose(_ value: String?) -> Bool? {
    guard let value else { return nil }
    switch value.lowercased() {
    case "true", "yes", "1", "always": return true
    case "false", "no", "0": return false
    default: return nil
    }
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics)
        var int: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else {
            return "#000000"
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

extension SettingsBackgroundImageFit {
    var displayName: String {
        switch self {
        case .contain: return "Contain".localized
        case .cover: return "Cover".localized
        case .stretch: return "Stretch".localized
        case .none: return "None".localized
        }
    }
}

extension SettingsCursorStyle {
    var displayName: String {
        switch self {
        case .bar: return "Bar".localized
        case .block: return "Block".localized
        case .underline: return "Underline".localized
        case .block_hollow: return "Block Hollow".localized
        }
    }
}

extension SettingsNotifyOnCommandFinish {
    var displayName: String {
        switch self {
        case .never: return "Never".localized
        case .unfocused: return "Unfocused".localized
        case .always: return "Always".localized
        }
    }
}

extension SettingsScrollbar {
    var displayName: String {
        switch self {
        case .system: return "System".localized
        case .never: return "Never".localized
        }
    }
}

extension SettingsClipboardAccess {
    var displayName: String {
        switch self {
        case .allow: return "Allow".localized
        case .deny: return "Deny".localized
        case .ask: return "Ask".localized
        }
    }
}

extension SettingsMacShortcuts {
    var displayName: String {
        switch self {
        case .allow: return "Allow".localized
        case .deny: return "Deny".localized
        case .ask: return "Ask".localized
        }
    }
}

extension SettingsAsyncBackend {
    var displayName: String {
        switch self {
        case .auto: return "Auto".localized
        case .epoll: return "epoll".localized
        case .io_uring: return "I/O Uring".localized
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let cfg = Ghostty.Config(at: nil, finalize: true)
        SettingsView()
            .environmentObject(SettingsModel(config: cfg))
            .frame(width: 820, height: 620)
    }
}
