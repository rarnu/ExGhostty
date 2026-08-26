import XCTest

@testable import Ghostty

/// AI 服务 system prompt 构造单元测试。
///
/// 核心验证：
/// - 终端上下文被原样嵌入 prompt
/// - OS family 权威性规则存在（macOS 终端按 macOS 语义回答命令问题，
///   修复用户实测的"问命令参数 AI 按 Linux 标准回答"问题）
/// - 资源快照仅作参考的说明存在
/// - 代码块格式约定保留（command / python fenced block）
final class AIAssistantServiceTests: XCTestCase {
    /// makeSystemPrompt 是 @MainActor 类的成员，测试需回到主线程调用。
    private func prompt(onMain: @escaping (String) -> Void) {
        let group = DispatchGroup()
        group.enter()
        Task { @MainActor in
            defer { group.leave() }
            onMain(AIAssistantService.makeSystemPrompt(terminalContext: sampleContext))
        }
        group.wait()
    }

    private let sampleContext = """
    Local environment
    Current directory: /Users/rarnu/Code/github/ExGhostty
    OS: Darwin 27.0.0 arm64
    OS family: macOS
    macOS version: 26.5
    CPU arch: Apple Silicon (arm64)
    """

    func testPromptEmbedsTerminalContextVerbatim() {
        prompt { p in
            XCTAssertTrue(p.contains(self.sampleContext), "终端上下文必须原样嵌入 system prompt")
        }
    }

    func testPromptDeclaresOSFamilyAuthoritative() {
        prompt { p in
            // OS family 权威规则：这是修复"mac 环境按 Linux 回答"问题的核心指令
            XCTAssertTrue(p.contains("OS family\" line is authoritative"))
            XCTAssertTrue(p.contains("macOS semantics"))
            XCTAssertTrue(p.contains("Never mix the two"))
        }
    }

    func testPromptTreatsResourceNumbersAsSnapshot() {
        prompt { p in
            // 资源数字是时刻快照，AI 不得当作实时值
            XCTAssertTrue(p.contains("point-in-time sample"))
            XCTAssertTrue(p.contains("reference values"))
        }
    }

    func testPromptPrefersInstalledTools() {
        prompt { p in
            XCTAssertTrue(p.contains("prefer tools the context says are installed"))
        }
    }

    func testPromptKeepsCodeBlockFormattingContract() {
        prompt { p in
            // 面板依赖 ```command / ```python 围栏代码块识别可执行内容
            XCTAssertTrue(p.contains("```command"))
            XCTAssertTrue(p.contains("```python"))
            XCTAssertTrue(p.contains("Do not include explanations inside the code blocks"))
        }
    }

    func testPromptHandlesEmptyContext() {
        let group = DispatchGroup()
        group.enter()
        var result = ""
        Task { @MainActor in
            defer { group.leave() }
            result = AIAssistantService.makeSystemPrompt(terminalContext: "")
        }
        group.wait()
        // 上下文为空时 prompt 仍完整可用
        XCTAssertTrue(result.contains("terminal assistant"))
        XCTAssertTrue(result.contains("OS family"))
    }
}