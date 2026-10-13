import Foundation
import AppKit
import OSLog

/// 将 Ghostty 配置、SSH 配置、端口转发规则、代码片段与 iCloud Drive 双向同步。
/// iCloud Drive 上的目录固定为 `~/Library/Mobile Documents/com~apple~CloudDocs/ExGhostty`。
final class ICloudSyncManager: ObservableObject {
    static let shared = ICloudSyncManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.xjai.exghostty",
        category: "ICloudSyncManager"
    )

    private let iCloudDirName = "ExGhostty"
    private let syncInterval: TimeInterval = 30.0
    private let timeTolerance: TimeInterval = 1.0
    private let lastChangeDefaultsKey = "icloud-sync-last-change"

    private var timer: Timer?
    private var isSyncing = false
    private(set) var isImporting = false

    /// 所有 iCloud Drive 文件操作在此串行队列执行。
    ///
    /// Mobile Documents 上的 fileExists / 属性读取 / Data(contentsOf:) 都可能
    /// 触发 iCloud 守护进程通信甚至网络下载，耗时可达数秒——这些操作曾在
    /// 主线程执行（30 秒轮询 + 配置变更触发），表现为鼠标变"等待"样式、
    /// 切换标签时界面短暂消失。真正的同步逻辑一律在后台跑，主线程只做
    /// store 数据快照与导入落库。
    private let syncQueue = DispatchQueue(label: "com.xjai.exghostty.icloud-sync", qos: .utility)

    /// 每类配置的本地最后修改时间（真实修改时间，关闭同步期间也会记录）。
    private var lastLocalChange: [SyncCategory: Date] = [:]

    /// iCloud Drive 根目录（`com~apple~CloudDocs`）。
    private var iCloudBaseURL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    /// 同步目录在 iCloud Drive 中的位置。
    private var iCloudDirectoryURL: URL? {
        iCloudBaseURL?.appendingPathComponent(iCloudDirName)
    }

    /// 本地同步缓存目录（位于 Application Support）。
    private var localSyncDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(iCloudDirName)
    }

    enum SyncCategory: String, CaseIterable {
        case config, ssh, portForward, codeSnippet

        var fileName: String {
            switch self {
            case .config: return "config"
            case .ssh: return "ssh.json"
            case .portForward: return "portforward.json"
            case .codeSnippet: return "snippets.json"
            }
        }
    }

    private init() {
        loadLastLocalChange()

        Task { @MainActor [weak self] in
            self?.loadEnabledState()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
    }

    // MARK: - 启用状态

    private(set) var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startPolling()
                Task { @MainActor [weak self] in
                    self?.sync()
                }
            } else {
                stopPolling()
            }
        }
    }

    @MainActor private func loadEnabledState() {
        // 默认开启：仅对从未设置过该开关的用户生效。
        let value = UserDefaults.ghostty.object(forKey: "icloud-sync") as? Bool ?? true
        if value != isEnabled {
            isEnabled = value
        }
    }

    @MainActor @objc private func configDidChange(_ notification: Notification) {
        // 只关心全局配置变更，忽略 surface 配置。
        guard notification.object == nil else { return }
        loadEnabledState()
        if isEnabled {
            sync()
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 公开接口

    /// 立即执行一次完整同步。
    ///
    /// 主线程上只做状态检查与派发，真正的文件操作在 syncQueue 上执行
    /// （见 syncQueue 的注释）。
    @MainActor func sync() {
        guard isEnabled else { return }
        syncQueue.async { [weak self] in
            self?.performSync()
        }
    }

    /// 同步主体，必须在 syncQueue 上调用。
    private func performSync() {
        guard !isSyncing else { return }
        guard iCloudDriveAvailable() else {
            logger.info("iCloud Drive is not available, skipping sync")
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            try ensureDirectories()
            for category in SyncCategory.allCases {
                try sync(category: category)
            }
        } catch {
            logger.error("iCloud sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 本地数据发生变化时调用，触发同步。
    /// 无论同步是否开启，都会记录该类的本地最后修改时间，
    /// 以便之后开启同步时能按真实修改时间比较新旧。
    @MainActor func localDidChange(category: SyncCategory) {
        let enabled = isEnabled
        // lastLocalChange 与同步主体共享 syncQueue 线程域，避免主线程/后台竞争。
        syncQueue.async { [weak self] in
            guard let self else { return }
            self.lastLocalChange[category] = Date()
            self.persistLastLocalChange()
            if enabled { self.performSync() }
        }
    }

    // MARK: - 文件路径

    private func localURL(for category: SyncCategory) -> URL? {
        switch category {
        case .config:
            return (NSApp.delegate as? AppDelegate)?.ghostty.configFileURL
        case .ssh, .portForward, .codeSnippet:
            return localSyncDirectoryURL.appendingPathComponent(category.fileName)
        }
    }

    private func iCloudURL(for category: SyncCategory) -> URL? {
        return iCloudDirectoryURL?.appendingPathComponent(category.fileName)
    }

    // MARK: - 单类别同步

    private func sync(category: SyncCategory) throws {
        guard let localURL = localURL(for: category),
              let iCloudURL = iCloudURL(for: category) else { return }

        let localExists = FileManager.default.fileExists(atPath: localURL.path)
        let iCloudExists = FileManager.default.fileExists(atPath: iCloudURL.path)

        // SSH/端口转发/代码片段首次运行（本地镜像不存在）时的初始化处理。
        if !localExists && category != .config {
            if iCloudExists {
                // 云端已有数据：下载并导入，避免用本地旧数据覆盖云端。
                try copyPreservingAttributes(from: iCloudURL, to: localURL)
                try importFromLocal(category: category, sourceURL: localURL)
                markLocalChangeTime(category, modificationDate(of: localURL) ?? Date())
                logger.info("Initialized \(category.rawValue, privacy: .public) from iCloud")
            } else {
                // 云端也没有：用当前本地数据生成镜像并上传。
                try generateLocalMirrorIfNeeded(category: category)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try copyPreservingAttributes(from: localURL, to: iCloudURL)
                    markLocalChangeTime(category, modificationDate(of: localURL) ?? Date())
                    logger.info("Initialized \(category.rawValue, privacy: .public) to iCloud")
                }
            }
            return
        }

        if !localExists && !iCloudExists {
            return
        }

        if !iCloudExists {
            // 本地有、云端无：上传。
            if category != .config {
                try generateLocalMirrorIfNeeded(category: category)
            }
            try copyPreservingAttributes(from: localURL, to: iCloudURL)
            markLocalChangeTime(category, modificationDate(of: localURL) ?? Date())
            logger.info("Uploaded \(category.rawValue, privacy: .public) to iCloud")
            return
        }

        if !localExists {
            // 云端有、本地无：下载并导入。
            try copyPreservingAttributes(from: iCloudURL, to: localURL)
            try importFromLocal(category: category, sourceURL: localURL)
            markLocalChangeTime(category, modificationDate(of: localURL) ?? Date())
            logger.info("Downloaded \(category.rawValue, privacy: .public) from iCloud")
            return
        }

        // 双方都有数据：按真实修改时间比较。
        let iCloudMtime = modificationDate(of: iCloudURL) ?? .distantPast
        let localChangeTime: Date
        if category == .config {
            // 配置文件本身的修改时间即真实修改时间。
            localChangeTime = modificationDate(of: localURL) ?? .distantPast
        } else {
            // 使用保存时记录的真实修改时间（同步关闭期间也会记录）；
            // 没有记录时退化为镜像文件时间。
            localChangeTime = lastLocalChange[category] ?? modificationDate(of: localURL) ?? .distantPast
        }

        if iCloudMtime.timeIntervalSince(localChangeTime) > timeTolerance {
            // 云端更新：下载覆盖本地并导入。
            try copyPreservingAttributes(from: iCloudURL, to: localURL)
            try importFromLocal(category: category, sourceURL: localURL)
            markLocalChangeTime(category, iCloudMtime)
            logger.info("Imported \(category.rawValue, privacy: .public) from iCloud")
        } else if localChangeTime.timeIntervalSince(iCloudMtime) > timeTolerance {
            // 本地更新：重新生成镜像并上传。
            try generateLocalMirrorIfNeeded(category: category)
            try copyPreservingAttributes(from: localURL, to: iCloudURL)
            markLocalChangeTime(category, modificationDate(of: localURL) ?? Date())
            logger.info("Uploaded \(category.rawValue, privacy: .public) to iCloud")
        }
    }

    // MARK: - 本地镜像生成

    private func generateLocalMirrorIfNeeded(category: SyncCategory) throws {
        switch category {
        case .config:
            // 配置文件本身即为本地镜像。
            break
        case .ssh, .portForward, .codeSnippet:
            // store 是供 SwiftUI 使用的主线程对象：先在主线程快照并编码出 Data，
            // 再在当前（后台）队列写文件。
            let data: Data = try DispatchQueue.main.sync {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                encoder.dateEncodingStrategy = .iso8601
                switch category {
                case .config:
                    return Data()
                case .ssh:
                    return try encoder.encode(SSHSyncPayload(
                        connections: SSHStore.shared.connections,
                        groups: SSHStore.shared.groups
                    ))
                case .portForward:
                    return try encoder.encode(PortForwardStore.shared.rules)
                case .codeSnippet:
                    return try encoder.encode(CodeSnippetSyncPayload(
                        categories: CodeSnippetStore.shared.categories,
                        snippets: CodeSnippetStore.shared.snippets
                    ))
                }
            }
            try data.write(
                to: localSyncDirectoryURL.appendingPathComponent(category.fileName),
                options: .atomic
            )
        }
    }

    // MARK: - 导入本地镜像

    private func importFromLocal(category: SyncCategory, sourceURL: URL) throws {
        // 文件读取与 JSON 解码在当前（后台）队列执行——iCloud 占位文件的读取
        // 可能触发网络下载；store 变更则回到主线程，并用 isImporting 阻断
        // "导入 → save() → localDidChange → 再同步" 的回环。
        let data = try Data(contentsOf: sourceURL)

        switch category {
        case .config:
            DispatchQueue.main.sync {
                (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            }
        case .ssh:
            let payload = try JSONDecoder().decode(SSHSyncPayload.self, from: data)
            DispatchQueue.main.sync {
                self.isImporting = true
                defer { self.isImporting = false }
                SSHStore.shared.connections = payload.connections
                SSHStore.shared.groups = payload.groups
                SSHStore.shared.save()
            }
        case .portForward:
            let rules = try JSONDecoder().decode([PortForwardRule].self, from: data)
            DispatchQueue.main.sync {
                self.isImporting = true
                defer { self.isImporting = false }
                PortForwardStore.shared.rules = rules
                PortForwardStore.shared.save()
            }
        case .codeSnippet:
            let payload = try JSONDecoder().decode(CodeSnippetSyncPayload.self, from: data)
            DispatchQueue.main.sync {
                self.isImporting = true
                defer { self.isImporting = false }
                CodeSnippetStore.shared.categories = payload.categories
                CodeSnippetStore.shared.snippets = payload.snippets

                // 保证默认分类始终存在。
                if !CodeSnippetStore.shared.categories.contains(where: { $0.name == "Default" }) {
                    CodeSnippetStore.shared.categories.insert(CodeSnippetCategory(name: "Default"), at: 0)
                }

                CodeSnippetStore.shared.save()
            }
        }
    }

    // MARK: - 目录与文件工具

    private func iCloudDriveAvailable() -> Bool {
        guard let url = iCloudBaseURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: localSyncDirectoryURL,
            withIntermediateDirectories: true
        )
        if let iCloudDir = iCloudDirectoryURL {
            try FileManager.default.createDirectory(
                at: iCloudDir,
                withIntermediateDirectories: true
            )
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private func copyPreservingAttributes(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if value == "true" || value == "yes" || value == "1" { return true }
        if value == "false" || value == "no" || value == "0" { return false }
        return nil
    }

    // MARK: - 本地修改时间跟踪

    private func loadLastLocalChange() {
        guard let dict = UserDefaults.ghostty.dictionary(forKey: lastChangeDefaultsKey) as? [String: Double] else { return }
        for (key, value) in dict {
            if let category = SyncCategory(rawValue: key) {
                lastLocalChange[category] = Date(timeIntervalSince1970: value)
            }
        }
    }

    private func persistLastLocalChange() {
        var dict: [String: Double] = [:]
        for (category, date) in lastLocalChange {
            dict[category.rawValue] = date.timeIntervalSince1970
        }
        UserDefaults.ghostty.set(dict, forKey: lastChangeDefaultsKey)
    }

    private func markLocalChangeTime(_ category: SyncCategory, _ date: Date) {
        lastLocalChange[category] = date
        persistLastLocalChange()
    }
}

// MARK: - 同步负载

private struct SSHSyncPayload: Codable {
    var connections: [SSHConnection]
    var groups: [SSHGroup]
}

private struct CodeSnippetSyncPayload: Codable {
    var categories: [CodeSnippetCategory]
    var snippets: [CodeSnippet]
}
