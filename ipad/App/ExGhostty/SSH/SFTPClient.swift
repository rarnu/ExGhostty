//
//  SFTPClient.swift
//  ExGhostty_iPad
//
//  Minimal SFTP v3 client (draft-ietf-secsh-filexfer-02) running on an
//  NIOSSH child channel. Without a User Identity it uses the standard
//  "sftp" subsystem request (runs as the login user — with modern OpenSSH
//  this is usually sshd's internal-sftp, which is fine). With one, the
//  "sftp" subsystem can't be user-switched, so the client starts the
//  standalone `sftp-server -e` binary over an EXEC child channel wrapped
//  in `sudo -u <target>` — the password variant uses `sudo -A` with a
//  per-connection askpass helper file deployed under the login user's
//  home (sudo -S would steal the channel's stdin, destroying the SFTP
//  framing). Supports directory listing, stat, upload, download, remove,
//  rename and mkdir.
//

import Foundation
import NIOCore
import NIOSSH

// MARK: - Public model

struct SFTPItem: Identifiable, Equatable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: UInt32
    let modificationDate: Date?

    var id: String { path }
}

enum SFTPError: Error, LocalizedError {
    case unexpectedMessage(UInt8)
    case server(code: UInt32, message: String)
    case notConnected
    /// With a User Identity enabled we must exec the standalone
    /// sftp-server binary; when it can't be located anywhere on the host
    /// the identity mode cannot work at all.
    case sftpServerNotFound
    /// The identity-wrapped sftp-server started but never answered the
    /// SFTP handshake: sudo rejected the password, or NOPASSWD is not
    /// configured for the target user.
    case identitySwitchFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedMessage(let type):
            return "Unexpected SFTP message type \(type)"
        case .server(let code, let message):
            return message.isEmpty ? "SFTP error \(code)" : message
        case .notConnected:
            return "SFTP channel is not connected"
        case .sftpServerNotFound:
            return "远端找不到 sftp-server，无法以切换后的用户身份运行 SFTP"
        case .identitySwitchFailed:
            return "切换用户失败：sudo 密码错误或未配置 NOPASSWD"
        }
    }
}

// MARK: - Wire format

private enum SFTPMessageType: UInt8 {
    case init_ = 1, version = 2
    case open = 3, close = 4, read = 5, write = 6
    case stat = 16, lstat = 7
    case opendir = 11, readdir = 12
    case remove = 13, mkdir = 14, rmdir = 15, rename = 18
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
}

private enum SFTPStatus: UInt32 {
    case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4
}

private struct SFTPWriter {
    var buffer: ByteBuffer

    init(allocator: ByteBufferAllocator) {
        buffer = allocator.buffer(capacity: 256)
    }

    mutating func writeUInt8(_ value: UInt8) { buffer.writeInteger(value) }
    mutating func writeUInt32(_ value: UInt32) { buffer.writeInteger(value) }
    mutating func writeUInt64(_ value: UInt64) { buffer.writeInteger(value) }

    mutating func writeString(_ string: String) {
        let bytes = Array(string.utf8)
        buffer.writeInteger(UInt32(bytes.count))
        buffer.writeBytes(bytes)
    }

    mutating func writeByteString(_ bytes: [UInt8]) {
        buffer.writeInteger(UInt32(bytes.count))
        buffer.writeBytes(bytes)
    }
}

private struct SFTPReader {
    private(set) var buffer: ByteBuffer

    init(buffer: ByteBuffer) { self.buffer = buffer }

    var isAtEnd: Bool { buffer.readableBytes == 0 }

    mutating func readUInt8() -> UInt8? { buffer.readInteger() }
    mutating func readUInt32() -> UInt32? { buffer.readInteger() }
    mutating func readUInt64() -> UInt64? { buffer.readInteger() }

    mutating func readString() -> String? {
        guard let bytes: [UInt8] = readByteString() else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readByteString() -> [UInt8]? {
        guard let length: UInt32 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(length)) else { return nil }
        return bytes
    }
}

private struct SFTPAttributes {
    var size: UInt64 = 0
    var permissions: UInt32 = 0
    var modificationDate: Date? = nil

    var isDirectory: Bool { permissions & 0o170000 == 0o040000 }

    static let empty = SFTPAttributes()
}

private extension SFTPReader {
    mutating func readAttributes() -> SFTPAttributes? {
        guard let flags: UInt32 = readUInt32() else { return nil }
        var attrs = SFTPAttributes()
        if flags & 0x1 != 0 {
            guard let size: UInt64 = readUInt64() else { return nil }
            attrs.size = size
        }
        if flags & 0x2 != 0 {
            // uid/gid, unused
            guard readUInt32() != nil, readUInt32() != nil else { return nil }
        }
        if flags & 0x4 != 0 {
            guard let permissions: UInt32 = readUInt32() else { return nil }
            attrs.permissions = permissions
        }
        if flags & 0x8 != 0 {
            guard readUInt32() != nil, let mtime: UInt32 = readUInt32() else { return nil }
            attrs.modificationDate = Date(timeIntervalSince1970: TimeInterval(mtime))
        }
        if flags & 0x8000_0000 != 0 {
            guard let count: UInt32 = readUInt32() else { return nil }
            for _ in 0..<count {
                guard readString() != nil, readString() != nil else { return nil }
            }
        }
        return attrs
    }
}

private struct SFTPResponse {
    var type: UInt8
    var reader: SFTPReader
}

// MARK: - Channel handler

private final class SFTPChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var inbound = ByteBuffer()
    private var pending: [UInt32: EventLoopPromise<SFTPResponse>] = [:]
    private var nextRequestID: UInt32 = 0

    /// Failure reason delivered when the handshake times out (the remote
    /// command produced no SFTP VERSION — typical when the exec'd binary is
    /// missing or sudo rejected the password).
    private let handshakeTimeoutError: Error

    /// When set, the channel is opened with an EXEC request running this
    /// command (`sudo ... sftp-server -e`) instead of the "sftp" subsystem,
    /// so the server runs as the target user.
    private let execCommand: String?

    init(execCommand: String?, handshakeTimeoutError: Error = SFTPError.notConnected) {
        self.execCommand = execCommand
        self.handshakeTimeoutError = handshakeTimeoutError
    }

    func channelActive(context: ChannelHandlerContext) {
        func failAllAndClose(_ error: Error) {
            self.failAll(with: error)
            context.close(promise: nil)
        }
        // Request payloads are concrete nested structs, not enum cases.
        if let execCommand {
            let request = SSHChannelRequestEvent.ExecRequest(command: execCommand, wantReply: false)
            context.triggerUserOutboundEvent(request).whenComplete { result in
                if case .failure(let error) = result { failAllAndClose(error) }
            }
        } else {
            let request = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: false)
            context.triggerUserOutboundEvent(request).whenComplete { result in
                if case .failure(let error) = result { failAllAndClose(error) }
            }
        }
        // If the SFTP VERSION never arrives within the timeout, the server
        // never came up (missing binary / sudo auth failure / hung shell).
        // handshake() registers its response promise under UInt32.max; the
        // timeout failing it makes withCheckedThrowingContinuation resolve
        // instead of hanging forever. A late VERSION is harmless: removeValue
        // returns nil and the packet is dropped.
        context.eventLoop.scheduleTask(in: .seconds(8)) {
            if let handshakePromise = self.pending.removeValue(forKey: UInt32.max) {
                handshakePromise.fail(self.handshakeTimeoutError)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard payload.type == .channel, case .byteBuffer(var buffer) = payload.data else { return }
        // exec mode runs through a real shell: sudo/sh stderr chatter
        // (e.g. "sftp-server: command not found") arrives on .stdErr and
        // must not desynchronize the SFTP frame stream.
        inbound.writeBuffer(&buffer)
        drainPackets()
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(with: SFTPError.notConnected)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(with: error)
        context.close(promise: nil)
    }

    /// Sends a request packet (length prefix + type + request id + payload)
    /// and returns a future for its response. Must be called on the event loop.
    func sendRequest(
        type: SFTPMessageType,
        on context: ChannelHandlerContext,
        payload: (inout SFTPWriter) -> Void
    ) -> EventLoopPromise<SFTPResponse> {
        let id = nextRequestID
        nextRequestID &+= 1

        var writer = SFTPWriter(allocator: context.channel.allocator)
        writer.writeUInt8(type.rawValue)
        writer.writeUInt32(id)
        payload(&writer)

        var framed = context.channel.allocator.buffer(capacity: writer.buffer.readableBytes + 4)
        framed.writeInteger(UInt32(writer.buffer.readableBytes))
        framed.writeBuffer(&writer.buffer)

        let promise = context.eventLoop.makePromise(of: SFTPResponse.self)
        pending[id] = promise
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(framed))), promise: nil)
        return promise
    }

    private func drainPackets() {
        while inbound.readableBytes >= 4 {
            guard let length: UInt32 = inbound.getInteger(at: inbound.readerIndex) else { return }
            guard inbound.readableBytes >= 4 + Int(length) else { return }
            inbound.moveReaderIndex(forwardBy: 4)
            guard var packet = inbound.readSlice(length: Int(length)),
                  let type: UInt8 = packet.readInteger() else { return }

            var response: SFTPResponse
            if type == SFTPMessageType.version.rawValue {
                response = SFTPResponse(type: type, reader: SFTPReader(buffer: packet))
                // VERSION has no request id; complete the synthetic id used by INIT.
                if let promise = pending.removeValue(forKey: UInt32.max) {
                    promise.succeed(response)
                }
                continue
            }

            guard let id: UInt32 = packet.readInteger() else { continue }
            response = SFTPResponse(type: type, reader: SFTPReader(buffer: packet))
            if let promise = pending.removeValue(forKey: id) {
                promise.succeed(response)
            }
        }
    }

    private func failAll(with error: Error) {
        let promises = pending
        pending.removeAll()
        for (_, promise) in promises {
            promise.fail(error)
        }
    }
}

// MARK: - SFTPClient

final class SFTPClient {
    private let channel: Channel
    private let handler: SFTPChannelHandler

    private init(channel: Channel, handler: SFTPChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Locate the sftp-server binary as seen by the login user. Many
    /// distros don't put it on the default PATH (Debian: /usr/lib/openssh,
    /// RHEL: /usr/libexec/openssh, macOS: /usr/libexec, Alpine: /usr/libexec);
    /// the EXEC channel's shell usually can't find it bare, and after a sudo
    /// wrap the PATH shrinks further. Pure; unit-testable.
    static func sftpServerLocateCommand() -> String {
        "(command -v sftp-server 2>/dev/null || ls /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/libexec/sftp-server /usr/libexec/ssh/sftp-server /usr/lib64/openssh/sftp-server /usr/lib/ssh/sftp-server 2>/dev/null) | head -1"
    }

    /// Pure command builder for the exec-mode SFTP channel:
    /// no identity → the binary alone; passwordless identity → `sudo -n`;
    /// password identity → `sudo -A` + per-connection askpass helper (the
    /// SFTP channel's stdin carries the protocol framing, so `sudo -S`
    /// reading the password from stdin is not an option — macOS solves the
    /// same problem for rsync the same way). Unit-testable.
    static func sftpServerExecCommand(
        binaryPath: String,
        identity: SSHIdentity.Identity?,
        loginUsername: String,
        connectionID: UUID?
    ) -> String {
        let binary = binaryPath.isEmpty ? "sftp-server" : binaryPath
        let command = SSHIdentity.shellQuote(binary) + " -e"
        guard let identity, identity.username != loginUsername else { return command }
        let user = SSHIdentity.shellQuote(identity.username)
        if let password = identity.sudoPassword, !password.isEmpty, let connectionID {
            return "SUDO_ASKPASS=" + SSHIdentity.shellQuote(sftpAskpassPath(connectionID: connectionID)) +
                " sudo -A -u " + user + " " + command
        }
        return "sudo -n -u " + user + " " + command
    }

    /// Remote askpass helper location: per-connection file under the login
    /// user's home (owned/700 by the login user, so sudo -A can exec it).
    static func sftpAskpassPath(connectionID: UUID) -> String {
        "~/.exghostty/askpass_\(connectionID.uuidString)"
    }

    /// Pure script builder; unit-testable. The helper prints the sudo
    /// password (base64 round-trip keeps it out of shell interpretation).
    static func sftpAskpassScriptText(password: String) -> String {
        let b64 = Data(password.utf8).base64EncodedString()
        return "#!/bin/sh\necho " + b64 + " | base64 -d\n"
    }

    /// Deploys the askpass helper as the login user (execRaw: no identity
    /// wrap). Returns false when the deploy failed.
    private static func deploySftpAskpass(on session: SSHSession, password: String) async -> Bool {
        let path = SFTPClient.sftpAskpassPath(connectionID: session.config.id)
        let b64 = Data(SFTPClient.sftpAskpassScriptText(password: password).utf8).base64EncodedString()
        let quote = SSHIdentity.shellQuote
        let command = "mkdir -p " + quote("~/.exghostty") +
            " && echo " + quote(b64) + " | base64 -d > " + quote(path) +
            " && chmod 700 " + quote(path) + " && test -x " + quote(path)
        let result = try? await session.execRaw(command)
        return result?.exitStatus == 0
    }

    /// Opens an SFTP client on a fresh child channel of the session.
    /// Without a User Identity it requests the standard "sftp" subsystem
    /// (runs as the login user — with modern OpenSSH that's usually
    /// sshd's internal-sftp, which is fine). With one, the subsystem
    /// request itself can't be wrapped, so the standalone sftp-server
    /// binary is started over an EXEC child channel under sudo and the
    /// handshake fails after a timeout with a descriptive error.
    static func open(on session: SSHSession) async throws -> SFTPClient {
        let identity = session.config.effectiveIdentity

        execMode: do {
            // The binary must exist for exec mode; the locate step runs as
            // the login user (no identity wrap).
            let located = (try? await session.execRaw(SFTPClient.sftpServerLocateCommand()))?
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !located.isEmpty else { break execMode }

            if let identity, let sudoPassword = identity.sudoPassword, !sudoPassword.isEmpty {
                // Best-effort: a stale helper means the handshake times out
                // (described as an identity failure below), not a hang.
                _ = await SFTPClient.deploySftpAskpass(on: session, password: sudoPassword)
            }
            let command = SFTPClient.sftpServerExecCommand(
                binaryPath: located,
                identity: identity,
                loginUsername: session.config.username,
                connectionID: session.config.id
            )
            // The binary was located, so no VERSION within the timeout means
            // sudo rejected the password (or NOPASSWD is missing).
            let timeoutError: SFTPError = identity != nil ? .identitySwitchFailed : .sftpServerNotFound
            return try await makeSession(clientOn: session, command: command, handshakeTimeoutError: timeoutError)
        }
        // No usable sftp-server (or locate itself failed): fall back to the
        // standard subsystem, which always runs as the login user.
        return try await makeSession(clientOn: session, command: nil, handshakeTimeoutError: SFTPError.notConnected)
    }

    private static func makeSession(
        clientOn session: SSHSession,
        command: String?,
        handshakeTimeoutError: Error
    ) async throws -> SFTPClient {
        final class Box { var handler: SFTPChannelHandler? }
        let box = Box()

        let channel: Channel = try await withCheckedThrowingContinuation { continuation in
            session.createChildChannel { child in
                child.eventLoop.makeCompletedFuture {
                    let handler = SFTPChannelHandler(
                        execCommand: command,
                        handshakeTimeoutError: handshakeTimeoutError
                    )
                    box.handler = handler
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }.whenComplete { result in
                continuation.resume(with: result)
            }
        }

        guard let handler = box.handler else { throw SFTPError.notConnected }
        let client = SFTPClient(channel: channel, handler: handler)
        try await client.handshake()
        return client
    }

    func close() {
        channel.close(promise: nil)
    }

    // MARK: Handshake

    private func handshake() async throws {
        // SSH_FXP_INIT has a version field instead of a request id; the
        // response (VERSION) is matched with the synthetic id UInt32.max.
        let response = try await withChannelContext { context in
            let id = UInt32.max
            var writer = SFTPWriter(allocator: context.channel.allocator)
            writer.writeUInt8(SFTPMessageType.init_.rawValue)
            writer.writeUInt32(3) // protocol version
            var framed = context.channel.allocator.buffer(capacity: writer.buffer.readableBytes + 4)
            framed.writeInteger(UInt32(writer.buffer.readableBytes))
            framed.writeBuffer(&writer.buffer)
            let promise = self.handler.sendRawRequest(id: id, on: context, packet: framed)
            return promise
        }
        guard response.type == SFTPMessageType.version.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
    }

    // MARK: Directory listing

    func listDirectory(_ path: String) async throws -> [SFTPItem] {
        let handle = try await openDirectory(path)
        defer { closeHandle(handle) }

        var items: [SFTPItem] = []
        while true {
            let response = try await request(.readdir) { $0.writeByteString(handle) }
            switch response.type {
            case SFTPMessageType.name.rawValue:
                var reader = response.reader
                guard let count: UInt32 = reader.readUInt32() else {
                    throw SFTPError.unexpectedMessage(response.type)
                }
                for _ in 0..<count {
                    guard let name = reader.readString(),
                          reader.readString() != nil, // longname, unused
                          let attrs = reader.readAttributes() else { continue }
                    if name == "." || name == ".." { continue }
                    let itemPath = path == "/" ? "/\(name)" : "\(path)/\(name)"
                    items.append(SFTPItem(
                        name: name,
                        path: itemPath,
                        isDirectory: attrs.isDirectory,
                        size: attrs.size,
                        permissions: attrs.permissions,
                        modificationDate: attrs.modificationDate
                    ))
                }
            case SFTPMessageType.status.rawValue:
                let status = try parseStatus(response.reader)
                if status.code == SFTPStatus.eof.rawValue { return items }
                throw SFTPError.server(code: status.code, message: status.message)
            default:
                throw SFTPError.unexpectedMessage(response.type)
            }
        }
    }

    // MARK: Stat

    func stat(_ path: String) async throws -> SFTPItem? {
        let response = try await request(.lstat) { $0.writeString(path) }
        if response.type == SFTPMessageType.status.rawValue {
            let status = try parseStatus(response.reader)
            if status.code == SFTPStatus.noSuchFile.rawValue { return nil }
            throw SFTPError.server(code: status.code, message: status.message)
        }
        guard response.type == SFTPMessageType.attrs.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        var reader = response.reader
        guard let attrs = reader.readAttributes() else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        let name = (path as NSString).lastPathComponent
        return SFTPItem(
            name: name,
            path: path,
            isDirectory: attrs.isDirectory,
            size: attrs.size,
            permissions: attrs.permissions,
            modificationDate: attrs.modificationDate
        )
    }

    // MARK: File transfer

    func download(remotePath: String, to localURL: URL, progress: (@Sendable (UInt64) -> Void)? = nil) async throws {
        let handle = try await openFile(remotePath, flags: 0x1, attrs: .empty)
        defer { closeHandle(handle) }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: localURL)
        defer { try? file.close() }

        var offset: UInt64 = 0
        let chunkSize: UInt32 = 64 * 1024
        while true {
            let response = try await request(.read) {
                $0.writeByteString(handle)
                $0.writeUInt64(offset)
                $0.writeUInt32(chunkSize)
            }
            switch response.type {
            case SFTPMessageType.data.rawValue:
                var reader = response.reader
                guard let bytes = reader.readByteString() else {
                    throw SFTPError.unexpectedMessage(response.type)
                }
                if bytes.isEmpty { return }
                try file.write(contentsOf: bytes)
                offset += UInt64(bytes.count)
                progress?(offset)
            case SFTPMessageType.status.rawValue:
                let status = try parseStatus(response.reader)
                if status.code == SFTPStatus.eof.rawValue { return }
                throw SFTPError.server(code: status.code, message: status.message)
            default:
                throw SFTPError.unexpectedMessage(response.type)
            }
        }
    }

    func upload(localURL: URL, to remotePath: String, progress: (@Sendable (UInt64) -> Void)? = nil) async throws {
        let handle = try await openFile(remotePath, flags: 0x2 | 0x8 | 0x10, attrs: .empty) // write|creat|trunc
        defer { closeHandle(handle) }

        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }

        var offset: UInt64 = 0
        let chunkSize = 64 * 1024
        while true {
            let data = try file.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { return }
            let response = try await request(.write) {
                $0.writeByteString(handle)
                $0.writeUInt64(offset)
                $0.writeByteString(Array(data))
            }
            let status = try parseResponseStatus(response)
            guard status.code == SFTPStatus.ok.rawValue else {
                throw SFTPError.server(code: status.code, message: status.message)
            }
            offset += UInt64(data.count)
            progress?(offset)
        }
    }

    // MARK: File operations

    func removeFile(_ path: String) async throws {
        let status = try parseResponseStatus(try await request(.remove) { $0.writeString(path) })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    func removeDirectory(_ path: String) async throws {
        let status = try parseResponseStatus(try await request(.rmdir) { $0.writeString(path) })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    func makeDirectory(_ path: String) async throws {
        let status = try parseResponseStatus(try await request(.mkdir) {
            $0.writeString(path)
            $0.writeUInt32(0) // empty attrs
        })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        let status = try parseResponseStatus(try await request(.rename) {
            $0.writeString(oldPath)
            $0.writeString(newPath)
        })
        guard status.code == SFTPStatus.ok.rawValue else {
            throw SFTPError.server(code: status.code, message: status.message)
        }
    }

    // MARK: Internals

    private func openDirectory(_ path: String) async throws -> [UInt8] {
        let response = try await request(.opendir) { $0.writeString(path) }
        return try parseHandle(response)
    }

    private func openFile(_ path: String, flags: UInt32, attrs: SFTPAttributes) async throws -> [UInt8] {
        let response = try await request(.open) {
            $0.writeString(path)
            $0.writeUInt32(flags)
            $0.writeUInt32(0) // empty attrs
        }
        return try parseHandle(response)
    }

    private func closeHandle(_ handle: [UInt8]) {
        Task { try? await closeHandleAndWait(handle) }
    }

    private func closeHandleAndWait(_ handle: [UInt8]) async throws {
        let response = try await request(.close) { $0.writeByteString(handle) }
        _ = try parseResponseStatus(response)
    }

    private func parseHandle(_ response: SFTPResponse) throws -> [UInt8] {
        if response.type == SFTPMessageType.status.rawValue {
            let status = try parseStatus(response.reader)
            throw SFTPError.server(code: status.code, message: status.message)
        }
        guard response.type == SFTPMessageType.handle.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        var reader = response.reader
        guard let handle = reader.readByteString() else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        return handle
    }

    private func parseStatus(_ reader: SFTPReader) throws -> (code: UInt32, message: String) {
        var reader = reader
        guard let code: UInt32 = reader.readUInt32() else {
            throw SFTPError.unexpectedMessage(SFTPMessageType.status.rawValue)
        }
        let message = reader.readString() ?? ""
        return (code, message)
    }

    private func parseResponseStatus(_ response: SFTPResponse) throws -> (code: UInt32, message: String) {
        guard response.type == SFTPMessageType.status.rawValue else {
            throw SFTPError.unexpectedMessage(response.type)
        }
        return try parseStatus(response.reader)
    }

    /// Runs `body` on the channel's event loop, giving it the handler context,
    /// and awaits the resulting response future.
    private func request(
        _ type: SFTPMessageType,
        payload: @escaping (inout SFTPWriter) -> Void
    ) async throws -> SFTPResponse {
        try await withChannelContext { context in
            self.handler.sendRequest(type: type, on: context, payload: payload)
        }
    }

    private func withChannelContext(
        _ body: @escaping (ChannelHandlerContext) -> EventLoopPromise<SFTPResponse>
    ) async throws -> SFTPResponse {
        let future: EventLoopFuture<SFTPResponse> = channel.pipeline.context(handler: handler)
            .flatMap { context in
                body(context).futureResult
            }
        return try await future.get()
    }
}

// MARK: - Handler support for raw (id-less) requests

extension SFTPChannelHandler {
    /// Sends an already-framed packet and registers a pending promise under a
    /// caller-chosen id (used for INIT, whose response has no request id).
    func sendRawRequest(id: UInt32, on context: ChannelHandlerContext, packet: ByteBuffer) -> EventLoopPromise<SFTPResponse> {
        let promise = context.eventLoop.makePromise(of: SFTPResponse.self)
        pending[id] = promise
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(packet))), promise: nil)
        return promise
    }
}
