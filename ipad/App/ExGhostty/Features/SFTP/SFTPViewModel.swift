//
//  SFTPViewModel.swift
//  ExGhostty_iPad
//
//  View model for the SFTP file manager panel: opens an SFTPClient on the
//  shared SSHSession, browses directories, and performs file operations
//  (mkdir / rename / delete / upload / download) with progress reporting.
//  Directory downloads are packed remotely with tar into /tmp, fetched over
//  SFTP, extracted locally via TarGzArchive (SWCompression) and cleaned up.
//  Directory uploads go the other way: packed locally, uploaded to /tmp and
//  extracted remotely into the current directory.
//

import Foundation

@MainActor
final class SFTPViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct TransferProgress: Equatable {
        var title: String
        var sent: UInt64
        var total: UInt64
    }

    struct Breadcrumb: Identifiable, Hashable {
        let name: String
        let path: String
        var id: String { path }
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var currentPath: String = "/"
    @Published private(set) var items: [SFTPItem] = []
    @Published var showHiddenFiles = false
    @Published private(set) var isBusy = false
    @Published private(set) var transfer: TransferProgress?
    @Published var errorMessage: String?

    private let session: SSHSession
    private var client: SFTPClient?
    private var openTask: Task<Void, Never>?

    init(session: SSHSession) {
        self.session = session
    }

    deinit {
        openTask?.cancel()
        client?.close()
    }

    // MARK: - Lifecycle

    /// Opens the SFTP subsystem and loads the remote home directory.
    func open() {
        guard state != .loading else { return }
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else { return }
            state = .loading
            do {
                let client = try await SFTPClient.open(on: session)
                try Task.checkCancellation()
                self.client = client
                // The SFTP session starts in the login user's home even when
                // the target identity applies, so `pwd` would report the wrong
                // directory. Read the effective user's own home from passwd
                // instead (same trick as the Mac version). Best-effort: if
                // the lookup itself fails, fall back to "/" and let the
                // directory listing surface the real error.
                let home = (try? await remoteHomeDirectory(for: session.config)) ?? "/"
                currentPath = home.isEmpty ? "/" : home
                try await refresh()
                state = .loaded
            } catch {
                if !Task.isCancelled {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Called from onDisappear: stops pending work and closes the SFTP channel.
    func close() {
        openTask?.cancel()
        openTask = nil
        client?.close()
        client = nil
        state = .idle
    }

    // MARK: - Browsing

    var breadcrumbs: [Breadcrumb] {
        var result = [Breadcrumb(name: "/", path: "/")]
        var built = ""
        for component in currentPath.split(separator: "/") {
            built += "/" + component
            result.append(Breadcrumb(name: String(component), path: built))
        }
        return result
    }

    /// Directories first, then files, each sorted by name.
    var visibleItems: [SFTPItem] {
        items
            .filter { showHiddenFiles || !$0.name.hasPrefix(".") }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func navigate(to path: String) {
        guard path != currentPath else { return }
        currentPath = path
        Task { await refreshShowingErrors() }
    }

    func goUp() {
        navigate(to: Self.parentPath(of: currentPath))
    }

    func refreshShowingErrors() async {
        do {
            try await refresh()
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refresh() async throws {
        guard let client else { throw SFTPError.notConnected }
        items = try await client.listDirectory(currentPath)
    }

    // MARK: - File operations

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let client else { return }
        await performBusy {
            try await client.makeDirectory(Self.join(self.currentPath, trimmed))
        }
    }

    func rename(_ item: SFTPItem, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, let client else { return }
        await performBusy {
            try await client.rename(from: item.path, to: Self.join(self.currentPath, trimmed))
        }
    }

    func delete(_ item: SFTPItem) async {
        guard let client else { return }
        await performBusy {
            if item.isDirectory {
                do {
                    try await client.removeDirectory(item.path)
                } catch {
                    // rmdir only works on empty directories; fall back to a
                    // recursive shell delete for non-empty ones.
                    let result = try await self.session.exec("rm -rf \(Self.shellQuote(item.path))")
                    if let status = result.exitStatus, status != 0 {
                        throw SFTPError.server(
                            code: UInt32(status),
                            message: result.stderr.isEmpty ? "rm -rf 失败" : result.stderr
                        )
                    }
                }
            } else {
                try await client.removeFile(item.path)
            }
        }
    }

    /// Downloads a remote file into a per-download temp directory and returns
    /// the local URL for sharing / saving.
    func download(_ item: SFTPItem) async throws -> URL {
        guard let client else { throw SFTPError.notConnected }
        var total = item.size
        if let info = (try? await client.stat(item.path)) ?? nil {
            total = info.size
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localURL = directory.appendingPathComponent(item.name)

        transfer = TransferProgress(title: "下载 \(item.name)", sent: 0, total: total)
        defer { transfer = nil }
        try await client.download(remotePath: item.path, to: localURL) { [weak self] sent in
            Task { @MainActor in
                self?.transfer?.sent = sent
            }
        }
        return localURL
    }

    /// Downloads a remote directory as a .tar.gz: packs it with tar into the
    /// server's /tmp (guaranteed writable, unlike the item's parent), fetches
    /// the archive over SFTP, extracts it locally and removes both archives.
    /// Returns the extracted directory's local URL for sharing / saving.
    func downloadDirectory(_ item: SFTPItem) async throws -> URL {
        guard let client else { throw SFTPError.notConnected }
        let remoteArchive = "/tmp/exghostty-download-\(UUID().uuidString).tar.gz"

        transfer = TransferProgress(title: "打包 \(item.name)…", sent: 0, total: 0)
        let parent = Self.parentPath(of: item.path)
        let pack = "cd \(Self.shellQuote(parent)) && tar -czf " +
            "\(Self.shellQuote(remoteArchive)) \(Self.shellQuote(item.name))"
        let packResult = try await session.exec(pack)
        if let status = packResult.exitStatus, status != 0 {
            transfer = nil
            throw SFTPError.server(
                code: UInt32(status),
                message: packResult.stderr.isEmpty ? "远程打包失败" : packResult.stderr
            )
        }
        // Best-effort remote cleanup once the transfer below has finished.
        defer {
            Task {
                _ = try? await session.exec("rm -f \(Self.shellQuote(remoteArchive))")
            }
        }

        let total = ((try? await client.stat(remoteArchive)) ?? nil)?.size ?? 0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("\(item.name).tar.gz")

        transfer = TransferProgress(title: "下载 \(item.name).tar.gz", sent: 0, total: total)
        try await client.download(remotePath: remoteArchive, to: archiveURL) { [weak self] sent in
            Task { @MainActor in
                self?.transfer?.sent = sent
            }
        }

        transfer = TransferProgress(title: "解压 \(item.name)…", sent: 0, total: 0)
        defer { transfer = nil }
        let extractRoot = directory.appendingPathComponent("extracted", isDirectory: true)
        try TarGzArchive.extract(archiveURL: archiveURL, into: extractRoot)
        try? FileManager.default.removeItem(at: archiveURL)
        return extractRoot.appendingPathComponent(item.name)
    }

    /// True when the given editor (e.g. "fresh") is on the remote PATH.
    /// Used before sending "<editor> <path>" to the terminal.
    func isEditorInstalled(_ editor: String) async -> Bool {
        let result = try? await session.exec("which \(editor) 2>/dev/null || true")
        return !(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Uploads a local file into the current directory.
    func upload(localURL: URL) async throws {
        guard let client else { throw SFTPError.notConnected }
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attributes[.size] as? UInt64) ?? 0

        transfer = TransferProgress(title: "上传 \(localURL.lastPathComponent)", sent: 0, total: total)
        defer { transfer = nil }
        try await client.upload(
            localURL: localURL,
            to: Self.join(currentPath, localURL.lastPathComponent)
        ) { [weak self] sent in
            Task { @MainActor in
                self?.transfer?.sent = sent
            }
        }
        try await refresh()
    }

    /// Uploads a local directory into the current directory: packs it into a
    /// .tar.gz locally, uploads the archive to the server's /tmp (guaranteed
    /// writable) and extracts it remotely.
    func uploadDirectory(localURL: URL) async throws {
        guard let client else { throw SFTPError.notConnected }
        let name = localURL.lastPathComponent

        transfer = TransferProgress(title: "打包 \(name)…", sent: 0, total: 0)
        let archiveData = try TarGzArchive.pack(directoryAt: localURL)
        // client.upload works on file URLs, so stage the archive on disk.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-upload-\(UUID().uuidString).tar.gz")
        try archiveData.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }

        let remoteArchive = "/tmp/exghostty-upload-\(UUID().uuidString).tar.gz"
        transfer = TransferProgress(title: "上传 \(name).tar.gz", sent: 0, total: UInt64(archiveData.count))
        try await client.upload(localURL: staging, to: remoteArchive) { [weak self] sent in
            Task { @MainActor in
                self?.transfer?.sent = sent
            }
        }

        transfer = TransferProgress(title: "解压 \(name)…", sent: 0, total: 0)
        defer { transfer = nil }
        let extract = "cd \(Self.shellQuote(currentPath)) && tar -xzf \(Self.shellQuote(remoteArchive))"
        let result = try await session.exec(extract)
        // The remote archive is temporary either way; clean it up best-effort.
        _ = try? await session.exec("rm -f \(Self.shellQuote(remoteArchive))")
        if let status = result.exitStatus, status != 0 {
            throw SFTPError.server(
                code: UInt32(status),
                message: result.stderr.isEmpty ? "远程解压失败" : result.stderr
            )
        }
        try await refresh()
    }

    // MARK: - Helpers

    /// Reads the effective user's home directory from /etc/passwd. New SSH
    /// child channels always start in the *login* user's home, so `pwd` is
    /// not a substitute. Runs as the login user (execRaw) — the query must
    /// see the target user's passwd entry, which is world-readable.
    private func remoteHomeDirectory(for config: SSHConnectionConfig) async throws -> String {
        let username = config.effectiveUsername
        let command = SFTPViewModel.homeLookupCommand(for: username)
        let result = try await session.execRaw(command)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pure command builder for the passwd lookup; unit-testable.
    /// The grep pattern interpolates the username (in BRE a bare name is
    /// literal, and the `^` anchor + `:` suffix pin the entry column).
    static func homeLookupCommand(for username: String) -> String {
        "(getent passwd \(username) 2>/dev/null || grep -m1 '^\(username):' /etc/passwd) | cut -d: -f6"
    }

    /// Runs a mutating operation with the busy flag, refreshes the listing
    /// afterwards, and surfaces failures through `errorMessage`.
    private func performBusy(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            try await refresh()
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    static func parentPath(of path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
