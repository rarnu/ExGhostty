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

    func testRequiresInstallCheckOnlyForFresh() {
        // fresh 需要预检查 + 一键安装；其他编辑器（含 tode）不检查
        XCTAssertTrue(SettingsTerminalEditor.fresh.requiresInstallCheck)
        for editor in SettingsTerminalEditor.allCases where editor != .fresh {
            XCTAssertFalse(editor.requiresInstallCheck, "\(editor.rawValue) 不应触发安装检查")
        }
    }

    func testRawValueParsing() {
        // 已知值解析，未知值返回 nil（current 据此回退 fresh）
        XCTAssertEqual(SettingsTerminalEditor(rawValue: "tode"), .tode)
        XCTAssertEqual(SettingsTerminalEditor(rawValue: "fresh"), .fresh)
        XCTAssertNil(SettingsTerminalEditor(rawValue: "not-a-real-editor"))
    }
}