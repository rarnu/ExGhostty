import XCTest

@testable import Ghostty

/// 设置窗口 General 分类的终端编辑器选项测试。
final class SettingsTerminalEditorTests: XCTestCase {

    func testAllCasesIncludesTode() {
        // 新增的 tode 选项必须出现在 Picker（依赖 CaseIterable）
        XCTAssertTrue(SettingsTerminalEditor.allCases.contains(.tode))
    }

    func testTodeRawValueMatchesCommandName() {
        // rawValue 会被直接拼进终端命令 "tode <path>"
        XCTAssertEqual(SettingsTerminalEditor.tode.rawValue, "tode")
    }

    func testRawValueParsing() {
        // 已知值解析，未知值返回 nil（current 据此回退 fresh）
        XCTAssertEqual(SettingsTerminalEditor(rawValue: "tode"), .tode)
        XCTAssertEqual(SettingsTerminalEditor(rawValue: "fresh"), .fresh)
        XCTAssertNil(SettingsTerminalEditor(rawValue: "not-a-real-editor"))
    }

    // MARK: - 安装预检查支持（所有编辑器都要能检查 + 能安装）

    func testEveryEditorHasInstallCommand() {
        // 所有编辑器都提供安装命令（未安装时确认框可展示 + 可执行）
        for editor in SettingsTerminalEditor.allCases {
            XCTAssertFalse(editor.installCommand.isEmpty, "\(editor.rawValue) 必须有安装命令")
        }
    }

    func testInstallCommandFormats() {
        // 官方安装脚本
        XCTAssertTrue(SettingsTerminalEditor.fresh.installCommand.contains("sinelaw/fresh"))
        XCTAssertTrue(SettingsTerminalEditor.tode.installCommand.contains("tode.sh/install"))
        XCTAssertTrue(SettingsTerminalEditor.micro.installCommand.contains("get.microeditor.net"))
        // 基础编辑器走包管理器，且目标包名 = 编辑器名
        XCTAssertTrue(SettingsTerminalEditor.vim.installCommand.contains("vim"))
        XCTAssertTrue(SettingsTerminalEditor.nano.installCommand.contains("nano"))
        // nvim 选项的包名是 neovim
        XCTAssertTrue(SettingsTerminalEditor.nvim.installCommand.contains("neovim"))
        // emacs 选项的包名是 emacs（发行版包名）
        XCTAssertTrue(SettingsTerminalEditor.emacs.installCommand.contains("emacs"))
    }
}