import AppKit
import SwiftUI
import os

/// 端口占用条目（TCP 监听），可来自本机或远程 SSH 主机。
struct PortUsageEntry: Identifiable, Hashable {
    /// 无法识别进程时（如远端无权限读取进程信息）为 -1。
    let pid: Int32
    let processName: String
    let address: String
    let port: UInt16
    /// 进程完整启动命令行（取自 ps），无法获取时为空。
    let commandLine: String

    var id: String { "\(pid)-\(address)-\(port)" }
}

/// 端口占用扫描器：本地终端扫描本机；SSH 终端通过 SSHCommandExecutor 扫描远程主机。
final class PortUsageStore: ObservableObject {
    private static let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.xjai.exghostty",
        category: "PortUsageStore"
    )

    let connection: SSHConnection?

    @Published private(set) var entries: [PortUsageEntry] = []
    @Published private(set) var isScanning = false

    private var timer: Timer?

    init(connection: SSHConnection?) {
        self.connection = connection
    }

    /// 立即扫描一次，并开始定时自动刷新。
    func startAutoRefresh() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let connection = self.connection
        // detached:远程扫描要走 ssh,耗时不定,不能阻塞主线程。
        Task.detached { [weak self] in
            let result = await Self.scan(connection: connection)
            guard let self else { return }
            await MainActor.run {
                self.entries = result
                self.isScanning = false
            }
        }
    }

    /// 结束占用进程：本地直接 kill，远程通过 SSH 执行 kill。
    func kill(pid: Int32) async -> Bool {
        guard pid > 0 else { return false }
        if let connection {
            do {
                _ = try await SSHCommandExecutor.shared.execute(
                    remoteCommand: "kill -9 \(pid)",
                    connection: connection
                )
                return true
            } catch {
                return false
            }
        }
        return ProcessInspector.killProcess(pid: pid)
    }

    // MARK: - 扫描

    private static func scan(connection: SSHConnection?) async -> [PortUsageEntry] {
        if let connection {
            return await scanRemote(connection: connection)
        }
        return scanLocal()
    }

    /// 本机扫描：使用 `lsof -F` 的机器可读输出，避免按列解析的脆弱性。
    private static func scanLocal() -> [PortUsageEntry] {
        guard var text = runProcess(executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else {
            return []
        }
        // 追加本机进程的完整命令行（a<PID> <ARGS> 字段），供解析器按 PID 合并。
        if let ps = runProcess(executable: "/bin/ps", arguments: ["-eo", "pid=,args="]) {
            text += "\n" + psArgsFieldLines(ps)
        }
        return parseFieldOutput(text)
    }

    /// 同步执行进程并返回标准输出；先持续读到 EOF 再等待退出，进程运行期间管道
    /// 始终被排空，输出多大都不会因管道写满而死锁。
    private static func runProcess(executable: String, arguments: [String], environment: [String: String]? = nil) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let environment {
            task.environment = environment
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 把 `ps -eo pid=,args=` 的输出转换为 a<PID> <ARGS> 字段行。
    private static func psArgsFieldLines(_ psOutput: String) -> String {
        psOutput.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  Int32(trimmed[trimmed.startIndex..<space]) != nil else { return nil }
            return "a" + trimmed
        }.joined(separator: "\n")
    }

    /// 远端扫描：优先 lsof，退化到 ss / netstat；
    /// 三种来源统一输出 lsof -F pcn 风格字段（p<PID> / c<COMMAND> / n<ADDR:PORT>），复用同一解析器。
    /// 末尾追加 ps 的完整命令行（a<PID> <ARGS> 字段），供解析器按 PID 合并。
    /// 注意：脚本必须以 true 结尾保证退出码为 0 —— SSHCommandExecutor 在退出码非 0 时会
    /// 抛错并丢弃全部标准输出，不能让 ps/awk 附加段拖垮前面的端口扫描结果。
    private static let remoteScanScript = """
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP -sTCP:LISTEN -F pcn 2>/dev/null
    elif command -v ss >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
      ss -tlnp 2>/dev/null | awk '$1=="LISTEN" { la=$4; port=la; sub(/.*:/,"",port); addr=la; sub(/:[^:]*$/,"",addr); pid=""; cmd="?"; if (match($0,/pid=[0-9]+/)) pid=substr($0,RSTART+4,RLENGTH-4); if (match($0,/\\(\\("[^"]+"/)) cmd=substr($0,RSTART+3,RLENGTH-4); if (pid=="") pid="-1"; print "p" pid; print "c" cmd; print "n" addr ":" port }'
    elif command -v netstat >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
      netstat -tlnp 2>/dev/null | awk '$6=="LISTEN" { la=$4; port=la; sub(/.*:/,"",port); addr=la; sub(/:[^:]*$/,"",addr); pid="-1"; cmd="?"; if ($7 ~ /^[0-9]+\\//) { split($7,b,"/"); pid=b[1]; cmd=b[2] } print "p" pid; print "c" cmd; print "n" addr ":" port }'
    fi
    if command -v ps >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
      ps -eo pid=,args= 2>/dev/null | awk '{ pid=$1; $1=""; sub(/^ +/,""); if (pid ~ /^[0-9]+$/) print "a" pid " " $0 }'
    fi
    true
    """

    private static func scanRemote(connection: SSHConnection) async -> [PortUsageEntry] {
        do {
            // 不能用 execute():它等进程终止后才读管道,输出超过管道缓冲区(64KB)时
            // ssh 写满管道阻塞,双方死锁。改用 streamingInvocation 自行执行,
            // 由 runProcess 边跑边读,不受输出大小限制(端口多时输出会很大)。
            let invocation = try await SSHCommandExecutor.shared.streamingInvocation(
                remoteCommand: remoteScanScript,
                connection: connection
            )
            guard let output = runProcess(
                executable: invocation.executableURL.path,
                arguments: invocation.arguments,
                environment: invocation.environment
            ) else {
                return []
            }
            return parseFieldOutput(output)
        } catch {
            logger.warning("Remote port scan failed for \(connection.host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 解析 lsof -F pcn 风格字段流；a<PID> <ARGS> 行为进程完整命令行，按 PID 合并进条目。
    private static func parseFieldOutput(_ text: String) -> [PortUsageEntry] {
        let lines = text.components(separatedBy: .newlines)

        var argsByPid: [Int32: String] = [:]
        for line in lines where line.first == "a" {
            let rest = line.dropFirst()
            guard let space = rest.firstIndex(of: " "),
                  let pid = Int32(rest[rest.startIndex..<space]) else { continue }
            argsByPid[pid] = String(rest[rest.index(after: space)...])
        }

        var entries: [PortUsageEntry] = []
        var seen: Set<String> = []
        var pid: Int32 = 0
        var command = ""
        for line in lines {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? -1
                command = ""
            case "c":
                command = value
            case "n":
                guard !command.isEmpty else { continue }
                let name = value.replacingOccurrences(of: " (LISTEN)", with: "")
                guard let colon = name.lastIndex(of: ":") else { continue }
                guard let port = UInt16(name[name.index(after: colon)...]), port > 0 else { continue }
                let address = String(name[name.startIndex..<colon])
                let entry = PortUsageEntry(
                    pid: pid,
                    processName: command,
                    address: address,
                    port: port,
                    commandLine: argsByPid[pid] ?? ""
                )
                if seen.insert(entry.id).inserted {
                    entries.append(entry)
                }
            default:
                continue
            }
        }
        return entries.sorted { ($0.port, $0.processName, $0.pid) < ($1.port, $1.processName, $1.pid) }
    }
}

/// 右侧栏“端口占用管理”功能面板。
struct PortUsagePanelView: View {
    @StateObject private var store: PortUsageStore
    @State private var searchText: String = ""
    @State private var selectedEntry: PortUsageEntry? = nil

    init(terminalController: TerminalController?) {
        _store = StateObject(wrappedValue: PortUsageStore(connection: terminalController?.sshConnection))
    }

    private var filteredEntries: [PortUsageEntry] {
        if searchText.isEmpty { return store.entries }
        return store.entries.filter {
            $0.processName.localizedCaseInsensitiveContains(searchText) ||
            String($0.port).contains(searchText) ||
            $0.address.localizedCaseInsensitiveContains(searchText) ||
            $0.commandLine.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if store.entries.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            store.startAutoRefresh()
        }
        .onDisappear {
            store.stopAutoRefresh()
        }
        .sheet(item: $selectedEntry) { entry in
            FullCommandSheet(command: entry.commandLine)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("Port Usage".localized)
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search by keyword".localized, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .sidebarTooltip("Clear Search".localized)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor).opacity(0.6))
            .cornerRadius(6)

            Spacer()

            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Refresh".localized)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var listView: some View {
        List {
            ForEach(filteredEntries) { entry in
                entryRow(entry)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            if store.isScanning {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text("No listening ports".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func entryRow(_ entry: PortUsageEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.processName)
                        .font(.system(size: 14, weight: .medium))
                    if entry.pid > 0 {
                        Text(verbatim: "PID \(entry.pid)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Text(verbatim: "\(entry.address):\(entry.port)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !entry.commandLine.isEmpty {
                    Text(entry.commandLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            if entry.pid > 0 {
                Button(action: { confirmKill(entry) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
//                        .foregroundColor(.red)
                        .frame(minWidth: 44, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Kill Process".localized)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            if !entry.commandLine.isEmpty {
                Button("View Full Command".localized) {
                    selectedEntry = entry
                }
            }
            if entry.pid > 0 {
                Divider()
                Button(role: .destructive) {
                    confirmKill(entry)
                } label: {
                    Text("Kill Process".localized)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func confirmKill(_ entry: PortUsageEntry) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Terminate Process".localized
            alert.informativeText = L("Are you sure you want to terminate \"%@\" (PID %d)?", entry.processName, entry.pid)
            alert.addButton(withTitle: "OK".localized)
            alert.addButton(withTitle: "Cancel".localized)
            alert.buttons.first?.hasDestructiveAction = true

            let proceed = {
                Task {
                    let killed = await self.store.kill(pid: entry.pid)
                    if !killed {
                        self.showKillFailedAlert(entry)
                    }
                    self.store.refresh()
                }
            }

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn { proceed() }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                proceed()
            }
        }
    }

    private func showKillFailedAlert(_ entry: PortUsageEntry) {
        let alert = NSAlert()
        alert.messageText = "Unable to terminate process".localized
        alert.informativeText = L("Failed to terminate %@ (PID %d).", entry.processName, entry.pid)
        alert.addButton(withTitle: "OK".localized)
        if let win = NSApp.keyWindow {
            alert.beginSheetModal(for: win) { _ in }
        } else {
            alert.runModal()
        }
    }
}

// MARK: - 完整命令弹窗

struct FullCommandSheet: View {
    let command: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Launch Command".localized)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 16)

            ScrollView {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            HStack {
                Spacer()
                Button("Close".localized) {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .controlSize(.regular)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 240)
    }
}
