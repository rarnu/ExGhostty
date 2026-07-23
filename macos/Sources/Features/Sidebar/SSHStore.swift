import Foundation
import SwiftUI
import Combine
import OSLog

/// 管理 SSH 连接和分组的存储，带 UserDefaults 持久化
class SSHStore: ObservableObject {
    // MARK: - Published 属性

    @Published var connections: [SSHConnection] = []
    @Published var groups: [SSHGroup] = []
    @Published var searchText: String = ""

    // MARK: - 单例

    static let shared = SSHStore()

    private let connectionsKey = "ghostty_ssh_connections"
    private let groupsKey = "ghostty_ssh_groups"

    private init() {
        load()
    }

    // MARK: - 查询

    var filteredConnections: [SSHConnection] {
        if searchText.isEmpty { return connections }
        return connections.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func connections(for groupID: UUID) -> [SSHConnection] {
        connections.filter { $0.groupID == groupID }
    }

    var ungroupedConnections: [SSHConnection] {
        connections.filter { $0.groupID == nil }
    }

    // MARK: - CRUD 连接

    func addConnection(_ conn: SSHConnection) {
        connections.append(conn)
        save()
    }

    func removeConnection(_ id: UUID) {
        // 先通知视图即将变化
        objectWillChange.send()
        connections.removeAll { $0.id == id }
        var changed = false
        for i in connections.indices where connections[i].jumpHostID == id {
            connections[i].jumpHostID = nil
            connections[i].connectionMethod = .direct
            changed = true
        }
        if changed {
            objectWillChange.send()
        }
        save()
    }

    func updateConnection(_ conn: SSHConnection) {
        guard let i = connections.firstIndex(where: { $0.id == conn.id }) else { return }
        connections[i] = conn
        save()
    }

    // MARK: - CRUD 分组

    func addGroup(_ group: SSHGroup) {
        groups.append(group)
        save()
    }

    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in connections.indices where connections[i].groupID == id {
            connections[i].groupID = nil
        }
        // 显式通知数组变化（上面的属性赋值不会触发 didSet）
        objectWillChange.send()
        save()
    }

    func updateGroup(_ group: SSHGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i] = group
        save()
    }

    // MARK: - 持久化

    func save() {
        if let connData = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(connData, forKey: connectionsKey)
        }
        if let groupData = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(groupData, forKey: groupsKey)
        }
        UserDefaults.standard.synchronize()

        if !ICloudSyncManager.shared.isImporting {
            Task { @MainActor in
                ICloudSyncManager.shared.localDidChange(category: .ssh)
            }
        }
    }

    private func load() {
        if let connData = UserDefaults.standard.data(forKey: connectionsKey),
           let conns = try? JSONDecoder().decode([SSHConnection].self, from: connData) {
            connections = cleanupJumpHostReferences(conns)
        }
        if let groupData = UserDefaults.standard.data(forKey: groupsKey),
           let gs = try? JSONDecoder().decode([SSHGroup].self, from: groupData) {
            groups = gs
        }
    }

    /// 清理指向已不存在连接（包括自身）的跳板机引用，防止加载旧数据时显示幽灵项目
    private func cleanupJumpHostReferences(_ conns: [SSHConnection]) -> [SSHConnection] {
        let validIDs = Set(conns.map(\.id))
        return conns.map { conn in
            guard conn.connectionMethod == .jumpHost,
                  let jumpID = conn.jumpHostID,
                  (!validIDs.contains(jumpID) || jumpID == conn.id) else { return conn }
            var updated = conn
            updated.jumpHostID = nil
            updated.connectionMethod = .direct
            return updated
        }
    }
}

// MARK: - 端口转发存储

/// 管理端口转发规则，支持持久化、启动/停止、自启动。
class PortForwardStore: ObservableObject {
    @Published var rules: [PortForwardRule] = []

    static let shared = PortForwardStore()

    private let rulesKey = "ghostty_port_forward_rules"
    private var runningProcesses: [UUID: Process] = [:]
    private var runningScriptURLs: [UUID: URL] = [:]
    /// 记录用户主动停止的规则 ID；非主动终止的进程会在结束后自动重启。
    private var intentionallyStopped: Set<UUID> = []
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.xjai.exghostty",
        category: "PortForwardStore"
    )

    private init() {
        load()
    }

    // MARK: - CRUD

    func addRule(_ rule: PortForwardRule) {
        rules.append(rule)
        save()
    }

    func updateRule(_ rule: PortForwardRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    func removeRule(_ id: UUID) {
        stopRule(id)
        rules.removeAll { $0.id == id }
        save()
    }

    // MARK: - 持久化

    func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: rulesKey)
        UserDefaults.standard.synchronize()

        if !ICloudSyncManager.shared.isImporting {
            Task { @MainActor in
                ICloudSyncManager.shared.localDidChange(category: .portForward)
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: rulesKey),
              let loaded = try? JSONDecoder().decode([PortForwardRule].self, from: data) else {
            return
        }
        rules = loaded.map { rule in
            var r = rule
            r.isRunning = false
            return r
        }
    }

    // MARK: - 启动/停止

    /// 启动指定规则。
    func startRule(_ id: UUID) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        guard !rules[idx].isRunning else { return }
        guard let connID = rules[idx].sshConnectionID,
              let conn = SSHStore.shared.connections.first(where: { $0.id == connID }) else {
            return
        }

        // 用户主动启动时清除停止标记，避免被保活机制误判。
        intentionallyStopped.remove(id)

        let rule = rules[idx]
        let expectScript = makeExpectScript(rule: rule, connection: conn)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_portforward_\(rule.id.uuidString).exp")

        do {
            try expectScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        if conn.authMode == .password, !conn.password.isEmpty {
            env["SSHPASS"] = conn.password
        }
        process.environment = env

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleProcessTerminated(
                    id: id,
                    scriptURL: scriptURL,
                    exitCode: proc.terminationStatus
                )
            }
        }

        do {
            try process.run()
            runningProcesses[id] = process
            runningScriptURLs[id] = scriptURL
            rules[idx].isRunning = true
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    /// 停止指定规则。
    func stopRule(_ id: UUID) {
        // 标记为用户主动停止，进程终止后不再自动重启。
        intentionallyStopped.insert(id)

        guard let process = runningProcesses[id] else {
            if let idx = rules.firstIndex(where: { $0.id == id }) {
                rules[idx].isRunning = false
            }
            return
        }

        if let idx = rules.firstIndex(where: { $0.id == id }) {
            rules[idx].isRunning = false
        }

        // 对 local/dynamic 规则，直接通过监听端口定位 ssh 进程并强杀，
        // 避免 expect 或 ssh 忽略 SIGTERM 导致转发仍在生效。
        if let rule = rules.first(where: { $0.id == id }),
           (rule.type == .local || rule.type == .dynamic),
           rule.localListenPort > 0,
           let sshPID = ProcessInspector.pidListening(on: rule.localListenPort) {
            ProcessInspector.forceKill(pid: sshPID)
        }

        // 先尝试优雅终止 expect 进程。
        process.terminate()

        // 兜底：0.5 秒后如果 expect 进程仍在，主线程上强杀它及其子进程。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard let proc = self.runningProcesses[id], proc.isRunning else { return }
            let expectPID = Int32(proc.processIdentifier)
            for child in ProcessInspector.childPIDs(of: expectPID) {
                ProcessInspector.forceKill(pid: child)
            }
            ProcessInspector.forceKill(pid: expectPID)
        }
    }

    /// 切换规则的运行状态。
    func toggleRule(_ id: UUID) {
        guard let rule = rules.first(where: { $0.id == id }) else { return }
        if rule.isRunning {
            stopRule(id)
        } else {
            startRule(id)
        }
    }

    /// 停止全部规则，用于应用退出。
    func stopAll() {
        for id in runningProcesses.keys {
            stopRule(id)
        }

        // 等待进程真正退出，最多 2 秒，避免应用重启后端口仍被旧进程占用。
        let deadline = Date().addingTimeInterval(2.0)
        while !runningProcesses.isEmpty && Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.05)
            )
        }
    }

    // MARK: - 进程结束处理

    private func handleProcessTerminated(id: UUID, scriptURL: URL, exitCode: Int32) {
        runningProcesses.removeValue(forKey: id)
        runningScriptURLs.removeValue(forKey: id)
        if let idx = rules.firstIndex(where: { $0.id == id }) {
            rules[idx].isRunning = false
        }

        let logPath = logPath(for: id)
        let logTail = lastLogLines(path: logPath, count: 30)
        let ruleName = rules.first(where: { $0.id == id })?.name ?? id.uuidString
        logger.info("""
            Port forward \"\(ruleName)\" exited with code \(exitCode).
            Log tail:
            \(logTail)
            """)

        try? FileManager.default.removeItem(at: scriptURL)

        // 非用户主动停止时，延迟 2 秒自动重启，实现长时间保活。
        if !intentionallyStopped.contains(id) {
            logger.info("Restarting port forward \"\(ruleName)\" in 2 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                guard self.rules.first(where: { $0.id == id }) != nil else { return }
                // 如果用户在等待期间点了停止，则不再重启。
                guard !self.intentionallyStopped.contains(id) else {
                    self.intentionallyStopped.remove(id)
                    return
                }
                self.startRule(id)
            }
        } else {
            intentionallyStopped.remove(id)
        }
    }

    // MARK: - Expect 脚本

    private func makeExpectScript(rule: PortForwardRule, connection: SSHConnection) -> String {
        let sshArgs = sshArguments(rule: rule, connection: connection)
        let hasPassword = connection.authMode == .password && !connection.password.isEmpty

        if hasPassword {
            return """
            set timeout 15
            set password $env(SSHPASS)
            log_file -a "\(logPath(for: rule))"
            proc sshlog {msg} {
                puts "[clock format [clock seconds]] $msg"
                flush stdout
            }
            trap { sshlog "SIGTERM received"; exit 0 } SIGTERM
            sshlog "spawning: /usr/bin/ssh -N \(sshArgs)"
            spawn /usr/bin/ssh -N \(sshArgs)
            set ssh_pid [exp_pid -i $spawn_id]
            trap { catch { exec kill -TERM $ssh_pid }; exit 0 } SIGTERM
            expect {
                -nocase "password:" { send "$password\r" }
                timeout { sshlog "password timeout"; exit 1 }
            }
            sshlog "authenticated, holding tunnel"
            expect eof
            set wait_result [wait]
            set exit_status [lindex $wait_result 3]
            sshlog "ssh process exited with code $exit_status"
            """
        } else {
            return """
            log_file -a "\(logPath(for: rule))"
            proc sshlog {msg} {
                puts "[clock format [clock seconds]] $msg"
                flush stdout
            }
            trap { sshlog "SIGTERM received"; exit 0 } SIGTERM
            sshlog "spawning: /usr/bin/ssh -N \(sshArgs)"
            spawn /usr/bin/ssh -N \(sshArgs)
            set ssh_pid [exp_pid -i $spawn_id]
            trap { catch { exec kill -TERM $ssh_pid }; exit 0 } SIGTERM
            sshlog "tunnel started"
            expect eof
            set wait_result [wait]
            set exit_status [lindex $wait_result 3]
            sshlog "ssh process exited with code $exit_status"
            """
        }
    }

    private func sshArguments(rule: PortForwardRule, connection: SSHConnection) -> String {
        // ssh 对同名选项取先出现的值，因此把隧道必需的参数放在最前面：
        // - ExitOnForwardFailure：端口绑定失败时 ssh 直接退出并触发自动重启，
        //   避免"进程还在但转发未生效"；
        // - ServerAlive：即使连接配置关闭了心跳，隧道也强制开启保活，
        //   连接假死（断网/休眠/NAT 超时）后最多 interval*3 秒内退出并重建。
        let heartbeatSec = connection.heartbeatMs > 0 ? max(1, Int(connection.heartbeatMs / 1000)) : 15
        let tunnelOpts = "-o ExitOnForwardFailure=yes -o ServerAliveInterval=\(heartbeatSec) -o ServerAliveCountMax=3 "
        let base = tunnelOpts + connection.sshOptions
        switch rule.type {
        case .local:
            return "-L \(rule.localListenHost):\(rule.localListenPort):\(rule.remoteHost):\(rule.remotePort) \(base)\(connection.sshHostPart)"
        case .remote:
            return "-R \(rule.remotePort):localhost:\(rule.localServicePort) \(base)\(connection.sshHostPart)"
        case .dynamic:
            return "-D \(rule.localListenHost):\(rule.localListenPort) \(base)\(connection.sshHostPart)"
        }
    }

    private func logPath(for rule: PortForwardRule) -> String {
        logPath(for: rule.id)
    }

    private func logPath(for id: UUID) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_portforward_\(id.uuidString).log")
            .path
    }

    private func lastLogLines(path: String, count: Int) -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return "(no log)"
        }
        let lines = text.components(separatedBy: .newlines)
        let tail = lines.suffix(count)
        return tail.joined(separator: "\n")
    }

    /// 读取指定规则日志文件的最后若干行。
    func logContent(for ruleID: UUID, lineCount: Int = 50) -> String {
        lastLogLines(path: logPath(for: ruleID), count: lineCount)
    }

    /// 返回指定规则日志文件的 URL。
    func logURL(for ruleID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_portforward_\(ruleID.uuidString).log")
    }

    /// 清空指定规则的日志文件。
    func clearLog(for ruleID: UUID) {
        let url = logURL(for: ruleID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 确保指定规则的日志文件存在（用于外部编辑器打开）。
    func ensureLogFileExists(for ruleID: UUID) {
        let url = logURL(for: ruleID)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
    }
}

private extension SSHConnection {
    /// 用于端口转发的 host 部分（user@host）
    var sshHostPart: String {
        let userPrefix = username.isEmpty ? "" : "\(username)@"
        return "\(userPrefix)\(host)"
    }
}
