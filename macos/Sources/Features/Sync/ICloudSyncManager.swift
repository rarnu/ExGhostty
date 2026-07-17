import Foundation
import AppKit
import OSLog

/// 将 Ghostty 配置、SSH 配置、端口转发规则、代码片段与 iCloud Drive 双向同步。
/// iCloud Drive 上的目录固定为 `~/Library/Mobile Documents/com~apple~CloudDocs/ExGhostty`。
final class ICloudSyncManager: ObservableObject {
    static let shared = ICloudSyncManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "ICloudSyncManager"
    )

    private let iCloudDirName = "ExGhostty"
    private let syncInterval: TimeInterval = 30.0
    private let timeTolerance: TimeInterval = 1.0

    private var timer: Timer?
    private var isSyncing = false
    private(set) var isImporting = false

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
        let value = UserDefaults.ghostty.object(forKey: "icloud-sync") as? Bool ?? false
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
    @MainActor func sync() {
        guard isEnabled, !isSyncing else { return }
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
    @MainActor func localDidChange(category: SyncCategory) {
        guard isEnabled else { return }
        sync()
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

        if !localExists && !iCloudExists {
            return
        }

        if !iCloudExists {
            // 本地有、云端无：上传。
            try generateLocalMirrorIfNeeded(category: category)
            try copyPreservingAttributes(from: localURL, to: iCloudURL)
            logger.info("Uploaded \(category.rawValue, privacy: .public) to iCloud")
            return
        }

        if !localExists {
            // 云端有、本地无：下载并导入。
            try copyPreservingAttributes(from: iCloudURL, to: localURL)
            try importFromLocal(category: category, sourceURL: localURL)
            logger.info("Downloaded \(category.rawValue, privacy: .public) from iCloud")
            return
        }

        let localMtime = modificationDate(of: localURL) ?? .distantPast
        let iCloudMtime = modificationDate(of: iCloudURL) ?? .distantPast

        if iCloudMtime.timeIntervalSince(localMtime) > timeTolerance {
            // 云端更新：下载覆盖本地并导入。
            try copyPreservingAttributes(from: iCloudURL, to: localURL)
            try importFromLocal(category: category, sourceURL: localURL)
            logger.info("Imported \(category.rawValue, privacy: .public) from iCloud")
        } else if localMtime.timeIntervalSince(iCloudMtime) > timeTolerance {
            // 本地更新：重新生成镜像并上传。
            try generateLocalMirrorIfNeeded(category: category)
            try copyPreservingAttributes(from: localURL, to: iCloudURL)
            logger.info("Uploaded \(category.rawValue, privacy: .public) to iCloud")
        }
    }

    // MARK: - 本地镜像生成

    private func generateLocalMirrorIfNeeded(category: SyncCategory) throws {
        switch category {
        case .config:
            // 配置文件本身即为本地镜像。
            break
        case .ssh:
            let payload = SSHSyncPayload(
                connections: SSHStore.shared.connections,
                groups: SSHStore.shared.groups
            )
            try writeJSON(payload, to: localSyncDirectoryURL.appendingPathComponent(category.fileName))
        case .portForward:
            let payload = PortForwardStore.shared.rules
            try writeJSON(payload, to: localSyncDirectoryURL.appendingPathComponent(category.fileName))
        case .codeSnippet:
            let payload = CodeSnippetSyncPayload(
                categories: CodeSnippetStore.shared.categories,
                snippets: CodeSnippetStore.shared.snippets
            )
            try writeJSON(payload, to: localSyncDirectoryURL.appendingPathComponent(category.fileName))
        }
    }

    // MARK: - 导入本地镜像

    private func importFromLocal(category: SyncCategory, sourceURL: URL) throws {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        switch category {
        case .config:
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        case .ssh:
            let data = try Data(contentsOf: sourceURL)
            let payload = try JSONDecoder().decode(SSHSyncPayload.self, from: data)
            SSHStore.shared.connections = payload.connections
            SSHStore.shared.groups = payload.groups
            SSHStore.shared.save()
        case .portForward:
            let data = try Data(contentsOf: sourceURL)
            let rules = try JSONDecoder().decode([PortForwardRule].self, from: data)
            PortForwardStore.shared.rules = rules
            PortForwardStore.shared.save()
        case .codeSnippet:
            let data = try Data(contentsOf: sourceURL)
            let payload = try JSONDecoder().decode(CodeSnippetSyncPayload.self, from: data)
            CodeSnippetStore.shared.categories = payload.categories
            CodeSnippetStore.shared.snippets = payload.snippets

            // 保证默认分类始终存在。
            if !CodeSnippetStore.shared.categories.contains(where: { $0.name == "Default" }) {
                CodeSnippetStore.shared.categories.insert(CodeSnippetCategory(name: "Default"), at: 0)
            }

            CodeSnippetStore.shared.save()
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

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if value == "true" || value == "yes" || value == "1" { return true }
        if value == "false" || value == "no" || value == "0" { return false }
        return nil
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
