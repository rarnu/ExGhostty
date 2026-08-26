import XCTest

@testable import Ghostty

/// 终端环境信息采集器单元测试。
///
/// 覆盖：
/// - 探测脚本静态不变量（子 shell 包裹 / exit 0 守卫 / xtop 直传 / OS family 分支）
/// - stripThinkBlocks 思考块剥离（正常 / 未闭合 / 空块 / 无块）
final class EnvironmentCollectorTests: XCTestCase {

    // MARK: - 探测脚本不变量

    func testProbeScriptWrappedInSubshellWithExitZero() {
        let script = EnvironmentCollector.probeScript
        // 子 shell 包裹 + 恒退出 0：ProcessRunner 只信任 exit 0 的 stdout
        XCTAssertTrue(script.hasPrefix("("), "脚本必须以子 shell 开头")
        XCTAssertTrue(script.hasSuffix("exit 0"), "脚本必须以 exit 0 结束")
        XCTAssertTrue(script.contains("|| true"), "必须带 || true 兜底")
        // 括号配平
        XCTAssertEqual(script.filter { $0 == "(" }.count, script.filter { $0 == ")" }.count)
    }

    func testProbeScriptCapturesOSIdentity() {
        let script = EnvironmentCollector.probeScript
        // OS family 是 AI 区分 macOS/Linux 语义的权威依据
        XCTAssertTrue(script.contains("uname -s"))
        XCTAssertTrue(script.contains("OS family: macOS"))
        XCTAssertTrue(script.contains("OS family: Linux"))
        XCTAssertTrue(script.contains("sw_vers"))
        // Linux 发行版识别
        XCTAssertTrue(script.contains("/etc/os-release"))
    }

    func testProbeScriptFetchesXTOPSnapshotWithoutParsing() {
        let script = EnvironmentCollector.probeScript
        // xtop 存在性探测 + 单次 JSON 快照（不带 --stream，避免挂起）
        XCTAssertTrue(script.contains("command -v xtop"))
        XCTAssertTrue(script.contains("--all --json"))
        XCTAssertFalse(script.contains("--stream"), "探测脚本不得开启 xtop 流式输出")
        // 不做解析：JSON 原样直传，xtop 段内不得对输出做 awk/jq 解析
        let xtopSection = script
            .components(separatedBy: "T2: xtop system resource snapshot").last?
            .components(separatedBy: "T3: Git Context").first ?? ""
        XCTAssertFalse(xtopSection.contains("jq "), "xtop JSON 必须直传，不得 jq 解析")
        XCTAssertFalse(xtopSection.contains("awk"), "xtop JSON 必须直传，不得 awk 解析")
    }

    func testProbeScriptCollectsGitToolsAndEnvMarkers() {
        let script = EnvironmentCollector.probeScript
        // Git 上下文
        XCTAssertTrue(script.contains("git rev-parse --git-dir"))
        XCTAssertTrue(script.contains("git branch --show-current"))
        // 开发工具
        for tool in ["python3", "node", "go", "java", "rustc", "docker", "kubectl", "git"] {
            XCTAssertTrue(script.contains("command -v \(tool)"), "缺少 \(tool) 探测")
        }
        // 环境变量标记
        for env in ["VIRTUAL_ENV", "CONDA_DEFAULT_ENV", "GOPATH", "JAVA_HOME", "NVM_DIR"] {
            XCTAssertTrue(script.contains(env), "缺少 \(env) 标记")
        }
    }

    // MARK: - stripThinkBlocks

    private let openTag = "<" + "think"
    private let closeTag = "</" + "think" + ">"

    func testStripThinkBlocks_noBlocksUnchanged() {
        let input = "hello world"
        XCTAssertEqual(EnvironmentCollector.stripThinkBlocks(input), input)
    }

    func testStripThinkBlocks_singleBlock() {
        let input = "AAA \(openTag)hidden reasoning\(closeTag)CCC"
        XCTAssertEqual(EnvironmentCollector.stripThinkBlocks(input), "AAA CCC")
    }

    func testStripThinkBlocks_unclosedBlockTruncated() {
        let input = "AAA \(openTag)hidden reasoning without end"
        XCTAssertEqual(EnvironmentCollector.stripThinkBlocks(input), "AAA")
    }

    func testStripThinkBlocks_emptyBlock() {
        let input = "A\(openTag)\(closeTag)B"
        XCTAssertEqual(EnvironmentCollector.stripThinkBlocks(input), "AB")
    }

    func testStripThinkBlocks_trimsWhitespace() {
        let input = "  AAA \(openTag)x\(closeTag)CCC  "
        XCTAssertEqual(EnvironmentCollector.stripThinkBlocks(input), "AAA CCC")
    }
}
