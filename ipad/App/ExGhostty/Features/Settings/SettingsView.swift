//
//  SettingsView.swift
//  ExGhostty_iPad
//
//  Settings page with the Mac version's split layout: a category list on
//  the left and the detail pane on the right. Categories: General
//  (language / editor), Theme (574 bundled ghostty themes, applied live),
//  Appearance (bundled fonts + size), AI, Keys and About (author info and
//  project links, modeled on the Mac About dialog).
//  Settings apply live (UserDefaults-backed stores), so the top-left back
//  button just pops the page; no explicit save step is needed.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var l10n = LocalizationManager.shared

    @State private var selectedCategory: SettingsCategory = .general

    /// 忽略置空企图，保证右侧面板不为空（与 Mac 版一致）。
    private var selectedCategoryBinding: Binding<SettingsCategory?> {
        Binding(
            get: { selectedCategory },
            set: { newValue in
                if let newValue {
                    selectedCategory = newValue
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                categoryList
                    .frame(width: 200)

                Divider()

                ScrollView {
                    detailContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.black)
            .navigationTitle(L("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 设置均为 UserDefaults 即时落盘，返回即已保存。
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label(L("返回"), systemImage: "chevron.left")
                    }
                }
            }
        }
    }

    // MARK: - 分类列表（左栏）

    private var categoryList: some View {
        List(SettingsCategory.allCases, selection: selectedCategoryBinding) { category in
            Label(L(category.title), systemImage: category.icon)
                .frame(height: 38)
                .tag(category)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedCategory {
        case .general: generalSection
        case .theme: themeSection
        case .appearance: appearanceSection
        case .ai: aiSection
        case .keys: keysSection
        case .about: AboutSettingsView()
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(L("通用"))

            settingsRow(label: L("语言")) {
                Picker("", selection: $l10n.language) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
            }
            hintText(L("语言切换立即生效。"))

            settingsRow(label: L("编辑器")) {
                Picker("", selection: $settings.terminalEditor) {
                    ForEach(TerminalEditor.allCases) { editor in
                        Text(editor.rawValue).tag(editor.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            hintText(L("SFTP 文件列表中「使用编辑器打开」会在终端里执行该编辑器。"))
        }
    }

    // MARK: - 主题

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L("主题"))

            let columns = [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16),
            ]
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(TerminalThemeCatalog.all) { theme in
                    ThemeCell(
                        theme: theme,
                        isSelected: TerminalThemeCatalog.entry(for: settings.themeName).id == theme.id
                    )
                    .onTapGesture {
                        settings.themeName = theme.id
                    }
                }
            }

            hintText(L("主题立即应用到所有打开的终端会话。"))
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(L("外观"))

            settingsRow(label: L("字体")) {
                Picker("", selection: $settings.terminalFontName) {
                    ForEach(TerminalFontCatalog.all) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }
                .pickerStyle(.menu)
            }

            settingsRow(label: L("字号")) {
                Picker("", selection: $settings.terminalFontSize) {
                    ForEach(Array(stride(from: 9, through: 24, by: 1)), id: \.self) { size in
                        Text("\(size)").tag(Double(size))
                    }
                }
                .pickerStyle(.menu)
            }

            settingsRow(label: L("光标样式")) {
                Picker("", selection: $settings.terminalCursorStyle) {
                    Text(L("块状")).tag("block")
                    Text(L("下划线")).tag("underline")
                    Text(L("竖线")).tag("bar")
                }
                .pickerStyle(.menu)
            }

            settingsRow(label: L("光标闪烁")) {
                Toggle("", isOn: $settings.terminalCursorBlink)
                    .labelsHidden()
                    .tint(.teal)
            }
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(L("AI 助手"))

            settingsRow(label: "Endpoint", controlWidth: 360) {
                TextField("", text: $settings.aiEndpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow(label: "API Key", controlWidth: 360) {
                SecureField("", text: $settings.aiAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }

            settingsRow(label: "Model", controlWidth: 360) {
                TextField("", text: $settings.aiModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
            }

            hintText(L("兼容 OpenAI 的 /chat/completions 接口"))
        }
    }

    // MARK: - 密钥

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(L("密钥"))

            // 直接内嵌密钥列表与导入/删除，不再跳转二级页面。
            SSHKeyListContent()
        }
    }

    // MARK: - 布局辅助（对齐 Mac 版的行式布局）

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.bottom, 4)
    }

    /// 行式布局：左侧固定宽标签，右侧控件放进统一宽度的列里，
    /// 保证同一分区内所有控件的左缘和宽度对齐。
    private func settingsRow<Content: View>(
        label: String,
        controlWidth: CGFloat = 240,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .frame(width: 120, alignment: .leading)
            content()
                .frame(width: controlWidth, alignment: .leading)
            Spacer()
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - 分类

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, theme, appearance, ai, keys, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .theme: return "主题"
        case .appearance: return "外观"
        case .ai: return "AI 助手"
        case .keys: return "密钥"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .theme: return "paintpalette"
        case .appearance: return "paintbrush"
        case .ai: return "cpu"
        case .keys: return "key"
        case .about: return "info.circle"
        }
    }
}

/// SFTP「使用编辑器打开」所用的终端编辑器（与 Mac 版 SettingsTerminalEditor
/// 保持一致）。rawValue 即远端可执行文件名，持久化在 SettingsStore。
enum TerminalEditor: String, CaseIterable, Identifiable {
    case vim, nvim, nano, emacs, micro, fresh, tode

    var id: String { rawValue }

    /// 远端一键安装命令（未安装时供用户确认后在终端执行）。
    ///
    /// 优先官方安装脚本（`curl … | sh`），回退常见包管理器；
    /// 与 Mac 版 SettingsTerminalEditor.installCommand 保持一致。
    var installCommand: String {
        switch self {
        case .fresh:
            return "curl -fsSL https://raw.githubusercontent.com/sinelaw/fresh/refs/heads/master/scripts/install.sh | sh"
        case .tode:
            return "curl -fsSL https://tode.sh/install | bash"
        case .micro:
            return "curl -fsSL https://get.microeditor.net | sh"
        case .nvim:
            return "command -v brew >/dev/null 2>&1 && brew install neovim || curl -fsSL https://raw.githubusercontent.com/neovim/gh-vim-install/refs/heads/master/install.sh | sh"
        case .emacs:
            return "command -v apt-get >/dev/null 2>&1 && sudo apt-get install -y emacs-nox || command -v dnf >/dev/null 2>&1 && sudo dnf install -y emacs-nox || command -v pacman >/dev/null 2>&1 && sudo pacman -S --noconfirm emacs || command -v brew >/dev/null 2>&1 && brew install emacs"
        case .vim, .nano:
            // 基础编辑器随系统自带；缺失时按发行版提示安装
            return "command -v apt-get >/dev/null 2>&1 && sudo apt-get install -y \(rawValue) || command -v dnf >/dev/null 2>&1 && sudo dnf install -y \(rawValue) || command -v pacman >/dev/null 2>&1 && sudo pacman -S --noconfirm \(rawValue) || command -v brew >/dev/null 2>&1 && brew install \(rawValue)"
        }
    }
}

#Preview {
    SettingsView()
}
