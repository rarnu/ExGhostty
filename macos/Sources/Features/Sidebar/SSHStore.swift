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
        var conn = conn
        // 主机名去除首尾空白：带空格的 host 会让 rsync 的 host:path 解析失败
        // （"hostname contains invalid characters"），ssh 因按空格拆分参数不受影响。
        conn.host = conn.host.trimmingCharacters(in: .whitespaces)
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
        var conn = conn
        conn.host = conn.host.trimmingCharacters(in: .whitespaces)
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
    /// 各规则最近一次进程启动时间，用于判断本次运行是否已稳定。
    private var processStartDates: [UUID: Date] = [:]
    /// 连续重连失败次数；转发被确认稳定（或用户手动停止）后清零。
    private var consecutiveFailures: [UUID: Int] = [:]
    /// 被健康检查判定为"假通"（进程在但端口不通）而强杀的规则，
    /// 终止处理时无论运行多久都计为一次失败。
    private var killedByHealthCheck: Set<UUID> = []
    /// 本次运行已通过端到端探测验证的规则，断开后视为正常保活重连，不计失败。
    private var probeVerified: Set<UUID> = []
    /// 本地监听端口健康检查定时器。
    private var healthCheckTimer: Timer?
    /// 防止上一轮后台探测未结束时重入。
    private var healthCheckInFlight = false

    /// 自动重连的固定间隔（不做指数退避）。
    private let reconnectDelay: TimeInterval = 3
    /// 连续失败达到此次数后转入慢速静默重试（不弹窗、不打扰用户）。
    private let maxConsecutiveFailures = 5
    /// 慢速静默重试的间隔（应对合盖唤醒/断网后的长时间不可用）。
    private let slowReconnectDelay: TimeInterval = 15
    /// 进程存活超过该时长视为已稳定，之后的断开属于正常保活重连，不计入失败次数。
    private let stabilityThreshold: TimeInterval = 15
    /// 健康检查间隔与启动宽限期（宽限期内不判定端口状态）。
    private let healthCheckInterval: TimeInterval = 10
    private let healthCheckGracePeriod: TimeInterval = 20

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
        // 清理可能残留的控制通道套接字（上次进程被强杀时会留下）。
        try? FileManager.default.removeItem(atPath: ctlPath(for: id))

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
        } else if conn.authMode == .key, !conn.keyPassphrase.isEmpty {
            env["SSHPASS"] = conn.keyPassphrase
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
            processStartDates[id] = Date()
            killedByHealthCheck.remove(id)
            probeVerified.remove(id)
            startHealthCheckTimerIfNeeded()
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    /// 停止指定规则。
    func stopRule(_ id: UUID) {
        // 标记为用户主动停止，进程终止后不再自动重启。
        intentionallyStopped.insert(id)
        // 手动停止视为用户显式干预，重置失败计数与运行状态记录。
        consecutiveFailures[id] = 0
        processStartDates.removeValue(forKey: id)
        killedByHealthCheck.remove(id)
        probeVerified.remove(id)

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
        stopHealthCheckTimerIfIdle()

        let logPath = logPath(for: id)
        let logTail = lastLogLines(path: logPath, count: 30)
        let ruleName = rules.first(where: { $0.id == id })?.name ?? id.uuidString
        logger.info("""
            Port forward \"\(ruleName)\" exited with code \(exitCode).
            Log tail:
            \(logTail)
            """)

        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(atPath: ctlPath(for: id))

        let wasKilledByHealthCheck = killedByHealthCheck.remove(id) != nil
        let wasVerified = probeVerified.remove(id) != nil
        let uptime = processStartDates.removeValue(forKey: id).map { Date().timeIntervalSince($0) } ?? 0

        // 用户主动停止时不重启。
        guard !intentionallyStopped.contains(id) else {
            intentionallyStopped.remove(id)
            return
        }

        // 通过过端到端探测的运行（或存活超过阈值且非健康检查强杀）后的断开
        // 视为正常保活，直接重连并重置失败计数；否则计为一次重连失败。
        let wasStable = !wasKilledByHealthCheck && (wasVerified || uptime >= stabilityThreshold)
        if wasStable {
            consecutiveFailures[id] = 0
        } else {
            let failures = (consecutiveFailures[id] ?? 0) + 1
            consecutiveFailures[id] = failures
            // 连续失败达到阈值后不再弹窗打扰用户（睡眠唤醒/断网是常态），
            // 转入慢速静默重试：每 slowReconnectDelay 秒重连一次，直到网络恢复、
            // 隧道重新进入稳定状态（届时失败计数会被上方稳定路径清零）。
            if failures == maxConsecutiveFailures {
                logger.warning("""
                    Port forward "\(ruleName)" failed to reconnect \(failures) times; \
                    switching to silent slow retry.
                    """)
            }
        }

        // 快速重试阶段固定 reconnectDelay；连续失败达到阈值后转入慢速静默重试。
        let failures = consecutiveFailures[id] ?? 0
        let delay = failures >= maxConsecutiveFailures ? slowReconnectDelay : reconnectDelay
        logger.info("Restarting port forward \"\(ruleName)\" in \(Int(delay)) seconds...")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.rules.first(where: { $0.id == id }) != nil else { return }
            // 如果用户在等待期间点了停止，则不再重启。
            guard !self.intentionallyStopped.contains(id) else {
                self.intentionallyStopped.remove(id)
                return
            }
            self.startRule(id)
        }
    }

    // MARK: - 健康检查（发现"显示连着但实际不通"的假通状态）

    /// 有运行中的 local/dynamic 规则时启动定时健康检查。
    private func startHealthCheckTimerIfNeeded() {
        guard healthCheckTimer == nil else { return }
        let timer = Timer(timeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    /// 没有需要检查的转发进程时停止定时器。
    private func stopHealthCheckTimerIfIdle() {
        guard runningProcesses.isEmpty else { return }
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    /// 对运行中的规则做端到端健康检查：通过控制通道复用现有 SSH 会话执行
    /// 远端命令，能执行说明"会话 + 通道"整条链路真实可用；探测失败（含会话
    /// 假死导致的超时）则强杀进程触发自动重连。
    private func performHealthCheck() {
        guard !healthCheckInFlight else { return }
        struct Candidate {
            let id: UUID
            let rule: PortForwardRule
            let connection: SSHConnection
            let expectPID: Int32
        }
        let candidates: [Candidate] = runningProcesses.compactMap { id, process in
            guard process.isRunning,
                  let rule = rules.first(where: { $0.id == id }),
                  let start = processStartDates[id],
                  Date().timeIntervalSince(start) >= healthCheckGracePeriod,
                  let connID = rule.sshConnectionID,
                  let conn = SSHStore.shared.connections.first(where: { $0.id == connID }) else {
                return nil
            }
            return Candidate(id: id, rule: rule, connection: conn, expectPID: Int32(process.processIdentifier))
        }
        guard !candidates.isEmpty else { return }
        healthCheckInFlight = true

        // 探测要起子进程并等待，放到后台线程执行，结果回主线程处理。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let results = candidates.map { ($0, self.probeTunnel(rule: $0.rule, connection: $0.connection)) }
            DispatchQueue.main.async {
                defer { self.healthCheckInFlight = false }
                for (candidate, healthy) in results {
                    if healthy {
                        // 链路真实可用，重置失败计数并标记本次运行已验证。
                        self.consecutiveFailures[candidate.id] = 0
                        self.probeVerified.insert(candidate.id)
                        continue
                    }
                    // 进程可能刚好退出或被用户停止，二次确认后再强杀。
                    guard let process = self.runningProcesses[candidate.id], process.isRunning else { continue }
                    let name = candidate.rule.name.isEmpty ? candidate.id.uuidString : candidate.rule.name
                    self.logger.warning("""
                        Port forward \"\(name)\" failed the end-to-end probe; restarting.
                        """)
                    self.killedByHealthCheck.insert(candidate.id)
                    for child in ProcessInspector.childPIDs(of: candidate.expectPID) {
                        ProcessInspector.forceKill(pid: child)
                    }
                    ProcessInspector.forceKill(pid: candidate.expectPID)
                }
            }
        }
    }

    /// 探测结果：ok=链路正常；refused=服务端快速拒绝（如受限账号）；timeout=超时（会话假死）。
    private enum ProbeResult {
        case ok, refused, timeout
    }

    /// 端到端探测：经控制通道复用现有会话执行远端 `true`。
    /// - 会话假死时请求会挂起，按超时判定为失效；
    /// - 对禁止执行命令的受限服务器（ForceCommand 等），快速拒绝属误报，
    ///   local 规则再用 -W 直连目标地址复核，其余类型视为正常。
    private func probeTunnel(rule: PortForwardRule, connection: SSHConnection) -> Bool {
        switch muxExec(connection: connection, ruleID: rule.id, remoteCommand: "true", timeout: 8) {
        case .ok:
            return true
        case .timeout:
            return false
        case .refused:
            guard rule.type == .local else { return true }
            return muxForward(
                connection: connection,
                ruleID: rule.id,
                target: "\(rule.remoteHost):\(rule.remotePort)",
                timeout: 5
            ) != .refused
        }
    }

    /// 经控制通道在远端执行命令：超时前退出码 0 为 ok，非 0 为 refused；超时视为假死。
    private func muxExec(connection: SSHConnection, ruleID: UUID, remoteCommand: String, timeout: TimeInterval) -> ProbeResult {
        runMuxSlave(
            arguments: muxSlaveArguments(connection: connection, ruleID: ruleID) + [remoteCommand],
            holdStdinOpen: false,
            timeout: timeout,
            aliveAtTimeout: .timeout
        )
    }

    /// 经控制通道打开 direct-tcpip 通道：超时仍存活说明通道已打开（ok），快速非 0 退出为 refused。
    private func muxForward(connection: SSHConnection, ruleID: UUID, target: String, timeout: TimeInterval) -> ProbeResult {
        runMuxSlave(
            arguments: muxSlaveArguments(connection: connection, ruleID: ruleID, extra: ["-W", target]),
            holdStdinOpen: true,
            timeout: timeout,
            aliveAtTimeout: .ok
        )
    }

    /// 从属 ssh 的基础参数：仅复用控制通道，禁止交互。
    /// - ControlMaster=no：从属进程自身不得成为 master；
    /// - ProxyCommand=/usr/bin/false：控制通道失效（master 死亡/套接字残留）时，
    ///   ssh 会退化为新建直连并绕过探测语义，用恒失败的 ProxyCommand 堵死该回退。
    private func muxSlaveArguments(connection: SSHConnection, ruleID: UUID, extra: [String] = []) -> [String] {
        let userPrefix = connection.username.isEmpty ? "" : "\(connection.username)@"
        return [
            "-S", ctlPath(for: ruleID),
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-o", "ProxyCommand=/usr/bin/false",
        ] + extra + ["\(userPrefix)\(connection.host)"]
    }

    /// 运行一次从属 ssh 并按退出时机/退出码分类结果。
    private func runMuxSlave(
        arguments: [String],
        holdStdinOpen: Bool,
        timeout: TimeInterval,
        aliveAtTimeout: ProbeResult
    ) -> ProbeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments

        // -W 会在 stdin EOF 时立即退出，需要保持 stdin 打开。
        let stdinPipe = Pipe()
        process.standardInput = holdStdinOpen ? stdinPipe : FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .refused
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            try? stdinPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return aliveAtTimeout
        }
        try? stdinPipe.fileHandleForWriting.close()
        return process.terminationStatus == 0 ? .ok : .refused
    }

    // MARK: - Expect 脚本

    private func makeExpectScript(rule: PortForwardRule, connection: SSHConnection) -> String {
        let sshArgs = sshArguments(rule: rule, connection: connection)
        // 密码登录的密码、密钥登录的私钥 passphrase 都经 expect 自动应答：
        // 私钥带密码时 ssh 会先提示 "Enter passphrase for key ..."。
        let hasPassword = (connection.authMode == .password && !connection.password.isEmpty)
            || (connection.authMode == .key && !connection.keyPassphrase.isEmpty)

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
                -nocase "passphrase" { send "$password\r" }
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
        // - ServerAlive：即使连接配置关闭了心跳，隧道也强制开启保活（上限 15 秒），
        //   保证 NAT/防火墙空闲超时前有心跳流量；连接假死后最多 interval*3 秒内退出并重建；
        // - -M -S：让隧道 ssh 作为 control master 运行，健康检查可通过控制通道
        //   复用现有会话做端到端探测，无需重新认证。
        let userHeartbeatSec = connection.heartbeatMs > 0 ? max(1, Int(connection.heartbeatMs / 1000)) : 15
        let heartbeatSec = min(userHeartbeatSec, 15)
        let tunnelOpts = "-M -S \(ctlPath(for: rule.id)) -o ExitOnForwardFailure=yes " +
            "-o ServerAliveInterval=\(heartbeatSec) -o ServerAliveCountMax=3 "
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

    /// 控制通道（control master）套接字路径，用于健康检查的端到端探测。
    /// Unix 套接字路径上限约 104 字符，$TMPDIR 本身已占约 50，
    /// 因此文件名只取 UUID 前 12 位（冲突概率可忽略）。
    private func ctlPath(for id: UUID) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_pf_\(id.uuidString.prefix(12)).ctl")
            .path
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
