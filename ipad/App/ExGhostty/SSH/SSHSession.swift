//
//  SSHSession.swift
//  ExGhostty_iPad
//
//  Core SSH connection object shared by the terminal and all feature panels.
//  Built on NIOSSH: one transport channel per session, child channels for
//  shell / exec / sftp. Supports password and private-key authentication,
//  plus an optional jump host (ssh -J).
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

struct ExecResult {
    var stdout: String
    var stderr: String
    var exitStatus: Int?
}

enum SSHSessionError: Error, LocalizedError {
    case notConnected
    case invalidChannelType
    case missingPassword
    case authenticationFailed
    case authenticationRejected(String)
    case jumpHostFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH session is not connected"
        case .invalidChannelType: return "Server opened an unexpected channel type"
        case .missingPassword: return "No password stored for this connection"
        case .authenticationFailed: return "Authentication failed (server rejected all offered methods)"
        case .authenticationRejected(let detail): return "认证失败：\(detail)"
        case .jumpHostFailed(let detail): return "Jump host connection failed: \(detail)"
        }
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

/// Offers the private key first (if any), then falls back to password.
final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String?
    private let privateKey: NIOSSHPrivateKey?
    private var offeredKey = false
    private var offeredPassword = false
    private var attempted: [String] = []
    private var lastAvailable = NIOSSHAvailableUserAuthenticationMethods()

    init(username: String, password: String?, privateKey: NIOSSHPrivateKey?) {
        self.username = username
        self.password = password
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lastAvailable = availableMethods
        if let privateKey, !offeredKey, availableMethods.contains(.publicKey) {
            offeredKey = true
            attempted.append("密钥")
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey))
            )
            nextChallengePromise.succeed(offer)
            return
        }
        if let password, !offeredPassword, availableMethods.contains(.password) {
            offeredPassword = true
            attempted.append("密码")
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
            return
        }
        nextChallengePromise.fail(rejectionError())
    }

    private func rejectionError() -> Error {
        if privateKey == nil && password == nil {
            return SSHSessionError.authenticationRejected("该连接没有配置密码或密钥")
        }
        var serverMethods: [String] = []
        if lastAvailable.contains(.publicKey) { serverMethods.append("publickey") }
        if lastAvailable.contains(.password) { serverMethods.append("password") }
        if lastAvailable.contains(.hostBased) { serverMethods.append("hostbased") }
        let serverDesc = serverMethods.isEmpty
            ? "服务器未提供 password/publickey 认证（可能仅支持 keyboard-interactive，暂不支持）"
            : "服务器允许: \(serverMethods.joined(separator: ", "))"
        let triedDesc = attempted.isEmpty ? "未尝试任何方式" : "已尝试: \(attempted.joined(separator: "、"))（均被拒绝）"
        return SSHSessionError.authenticationRejected("\(triedDesc)；\(serverDesc)")
    }
}

private final class SessionErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

// MARK: - One-shot exec

private final class ExecCommandHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private var stdout = ByteBuffer()
    private var stderr = ByteBuffer()
    private var exitStatus: Int?
    private var continuation: CheckedContinuation<ExecResult, Error>?

    init(command: String, continuation: CheckedContinuation<ExecResult, Error>) {
        self.command = command
        self.continuation = continuation
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(request, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data else { return }
        switch payload.type {
        case .channel:
            stdout.writeBuffer(&buffer)
        case .stdErr:
            stderr.writeBuffer(&buffer)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = status.exitStatus
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(with: .success(ExecResult(
            stdout: String(buffer: stdout),
            stderr: String(buffer: stderr),
            exitStatus: exitStatus
        )))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(with: .failure(error))
        context.close(promise: nil)
    }

    private func finish(with result: Result<ExecResult, Error>) {
        let continuation = continuation
        self.continuation = nil
        switch result {
        case .success(let value): continuation?.resume(returning: value)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

// MARK: - Streaming exec

private final class StreamingExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    init(command: String, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.command = command
        self.continuation = continuation
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
        context.triggerUserOutboundEvent(request, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data, payload.type == .channel else { return }
        if let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty {
            continuation?.yield(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation?.finish()
        continuation = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
        context.close(promise: nil)
    }
}

// MARK: - SSHSession

final class SSHSession: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case closed
    }

    /// Credentials for the jump host (ssh -J). Set before connect().
    struct JumpSpec {
        var config: SSHConnectionConfig
        var password: String?
        var privateKey: NIOSSHPrivateKey?
    }

    let config: SSHConnectionConfig
    private let password: String?
    private let privateKey: NIOSSHPrivateKey?

    /// Optional jump host; must be set before connect().
    var jump: JumpSpec?

    /// -R 远程转发：远端 accept 的连接会以 forwardedTCPIP 子 channel 到达，
    /// 此闭包负责把它们接到本地服务（见 PortForwardRuntime）。主 transport
    /// 生效，跳板机 transport 不装。connect() 之前设置。
    var inboundForwardedTCPIPHandler: ((Channel) -> EventLoopFuture<Void>)?

    @Published private(set) var state: ConnectionState = .idle

    private var group: MultiThreadedEventLoopGroup?
    private var transport: Channel?
    private var jumpTransport: Channel?

    init(config: SSHConnectionConfig, password: String?, privateKey: NIOSSHPrivateKey? = nil) {
        self.config = config
        self.password = password
        self.privateKey = privateKey
    }

    var isConnected: Bool { state == .connected }

    // MARK: Transport lifecycle

    /// Serializes concurrent ensureConnected() calls (tab-level and
    /// terminal-view-level reconnects can fire together on foregrounding).
    private var connectInFlight = false

    /// Reconnects if the transport is dead; a no-op when already connected.
    /// Used by the auto-reconnect paths after iOS suspends the app (lock
    /// screen / background), which tears down the TCP connection.
    func ensureConnected() async throws {
        if await currentState == .connected, let transport, transport.isActive { return }
        guard !connectInFlight else { return }
        connectInFlight = true
        defer { connectInFlight = false }
        // 清掉失败/关闭状态残留的 group 和 transport，再整体重连。
        closeTransports()
        shutdownGroup()
        try await connect()
    }

    func connect() async throws {
        await setState(.connecting)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        self.group = group

        do {
            if let jump {
                let jumpChannel = try await openTransport(
                    host: jump.config.host,
                    port: jump.config.port,
                    authDelegate: FlexibleAuthDelegate(
                        username: jump.config.username,
                        password: jump.password,
                        privateKey: jump.privateKey
                    )
                )
                self.jumpTransport = jumpChannel
                let nested = try await openNestedTransport(
                    over: jumpChannel,
                    targetHost: config.host,
                    targetPort: config.port
                )
                self.transport = nested
            } else {
                self.transport = try await openTransport(
                    host: config.host,
                    port: config.port,
                    authDelegate: FlexibleAuthDelegate(
                        username: config.username,
                        password: password,
                        privateKey: privateKey
                    ),
                    inboundForwarding: inboundForwardedTCPIPHandler != nil
                )
            }
            await setState(.connected)
        } catch {
            await setState(.failed(error.localizedDescription))
            closeTransports()
            shutdownGroup()
            throw error
        }
    }

    func disconnect() {
        closeTransports()
        Task {
            shutdownGroup()
            await setState(.closed)
        }
    }

    private func closeTransports() {
        let channel = transport
        let jump = jumpTransport
        transport = nil
        jumpTransport = nil
        channel?.close(promise: nil)
        jump?.close(promise: nil)
    }

    /// Opens a plain TCP connection and runs the SSH handshake on it.
    private func openTransport(
        host: String,
        port: Int,
        authDelegate: NIOSSHClientUserAuthenticationDelegate,
        inboundForwarding: Bool = false
    ) async throws -> Channel {
        guard let group else { throw SSHSessionError.notConnected }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else { return }
                    try self.installSSHHandlers(
                        on: channel,
                        authDelegate: authDelegate,
                        inboundForwarding: inboundForwarding
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .connectTimeout(.seconds(10))

        let channel = try await bootstrap.connect(host: host, port: port).get()
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.transportClosed()
        }
        return channel
    }

    /// ssh -J: opens a directTCPIP channel through the jump host and runs a
    /// second SSH handshake on top of it.
    private func openNestedTransport(
        over jumpChannel: Channel,
        targetHost: String,
        targetPort: Int
    ) async throws -> Channel {
        guard jumpChannel.isActive, group != nil else {
            throw SSHSessionError.jumpHostFailed("jump host transport is closed")
        }
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let channelType = SSHChannelType.directTCPIP(.init(
            targetHost: targetHost,
            targetPort: targetPort,
            originatorAddress: originator
        ))

        let promise = jumpChannel.eventLoop.makePromise(of: Channel.self)
        jumpChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else {
                promise.fail(SSHSessionError.notConnected)
                return
            }
            switch result {
            case .failure(let error):
                promise.fail(error)
            case .success(let sshHandler):
                sshHandler.createChannel(promise, channelType: channelType) { [weak self] child, type in
                    guard case .directTCPIP = type else {
                        return child.eventLoop.makeFailedFuture(SSHSessionError.invalidChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        guard let self else { return }
                        // Child channels speak SSHChannelData; NIOSSHHandler expects
                        // raw bytes, so convert in between.
                        try child.pipeline.syncOperations.addHandler(SSHDataCodec())
                        try self.installSSHHandlers(
                            on: child,
                            authDelegate: FlexibleAuthDelegate(
                                username: self.config.username,
                                password: self.password,
                                privateKey: self.privateKey
                            ),
                            inboundForwarding: self.inboundForwardedTCPIPHandler != nil
                        )
                    }
                }
            }
        }
        let channel = try await promise.futureResult.get()
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.transportClosed()
        }
        return channel
    }

    private func installSSHHandlers(
        on channel: Channel,
        authDelegate: NIOSSHClientUserAuthenticationDelegate,
        inboundForwarding: Bool = false
    ) throws {
        // -R 远程转发时接收 forwardedTCPIP 入站 channel；否则保持 nil
        // （其余入站 channel 一律拒绝）。
        let inboundInitializer: ((Channel, SSHChannelType) -> EventLoopFuture<Void>)? =
            inboundForwarding ? { [weak self] child, type in
                guard case .forwardedTCPIP = type,
                      let handler = self?.inboundForwardedTCPIPHandler else {
                    return child.close()
                }
                return child.eventLoop.makeCompletedFuture {
                    _ = handler(child)
                }
            } : nil
        let sshHandler = NIOSSHHandler(
            role: .client(.init(
                userAuthDelegate: authDelegate,
                serverAuthDelegate: AcceptAllHostKeysDelegate()
            )),
            allocator: channel.allocator,
            inboundChildChannelInitializer: inboundInitializer
        )
        try channel.pipeline.syncOperations.addHandler(sshHandler)
        try channel.pipeline.syncOperations.addHandler(
            SessionErrorHandler { [weak self] error in
                self?.transportFailed(error)
            }
        )
    }

    // MARK: Exec

    /// Runs a command on a fresh child channel and collects its full output.
    /// When the connection has a User Identity configured, the command is
    /// wrapped in sudo so it runs as the target user.
    func exec(_ command: String) async throws -> ExecResult {
        let command = SSHIdentity.wrap(
            remoteCommand: command,
            as: config.effectiveIdentity,
            loginUsername: config.username
        )
        return try await runExecCommand(command)
    }

    /// Like `exec` but skips the User Identity sudo wrap, so the command runs
    /// as the login user. Use for lookups of the target user's own info (e.g.
    /// reading the effective user's home from /etc/passwd) and for
    /// infrastructure that must be owned by the login user — a double sudo
    /// wrap on those would be wrong.
    func execRaw(_ command: String) async throws -> ExecResult {
        try await runExecCommand(command)
    }

    private func runExecCommand(_ command: String) async throws -> ExecResult {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExecResult, Error>) in
            createChildChannel { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        ExecCommandHandler(command: command, continuation: continuation)
                    )
                }
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a command and yields stdout chunks as they arrive, until the channel closes.
    /// When the consumer stops iterating (task cancelled / stream finished),
    /// the channel is closed so the remote process does not keep running.
    func execStream(_ command: String) -> AsyncThrowingStream<Data, Error> {
        let command = SSHIdentity.wrap(
            remoteCommand: command,
            as: config.effectiveIdentity,
            loginUsername: config.username
        )
        return AsyncThrowingStream { continuation in
            createChildChannel { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        StreamingExecHandler(command: command, continuation: continuation)
                    )
                }
            }.whenComplete { result in
                switch result {
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .success(let channel):
                    continuation.onTermination = { _ in
                        channel.close(promise: nil)
                    }
                }
            }
        }
    }

    // MARK: Port forwarding

    /// -L/-D：请求远端建立一条到 targetHost:targetPort 的出站连接
    /// （directTCPIP 子 channel）。initializer 负责装 channel 的 handler。
    @discardableResult
    func createDirectTCPIPChannel(
        targetHost: String,
        targetPort: Int,
        _ initializer: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        guard let transport, transport.isActive, group != nil else {
            return MultiThreadedEventLoopGroup.singleton.next()
                .makeFailedFuture(SSHSessionError.notConnected)
        }
        let originator = (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))!
        let channelType = SSHChannelType.directTCPIP(.init(
            targetHost: targetHost,
            targetPort: targetPort,
            originatorAddress: originator
        ))
        let promise = transport.eventLoop.makePromise(of: Channel.self)
        transport.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                promise.fail(error)
            case .success(let sshHandler):
                sshHandler.createChannel(promise, channelType: channelType) { child, type in
                    guard case .directTCPIP = type else {
                        return child.eventLoop.makeFailedFuture(SSHSessionError.invalidChannelType)
                    }
                    return initializer(child)
                }
            }
        }
        return promise.futureResult
    }

    /// -R：请求远端监听 host:port 并把收到的连接以 forwardedTCPIP 转发回来。
    /// 远端拒绝（端口被占、禁止转发等）会 throw。
    func requestRemoteForward(listenHost: String, listenPort: Int) async throws {
        guard let transport, transport.isActive else { throw SSHSessionError.notConnected }
        let sshHandler = try await transport.pipeline.handler(type: NIOSSHHandler.self).get()
        let promise = transport.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        transport.eventLoop.execute {
            sshHandler.sendTCPForwardingRequest(
                .listen(host: listenHost, port: listenPort),
                promise: promise
            )
        }
        _ = try await promise.futureResult.get()
    }

    // MARK: Child channels

    /// Creates a `.session` child channel on the transport. The initializer must
    /// install the channel's handlers.
    @discardableResult
    func createChildChannel(
        _ initializer: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        guard let transport, transport.isActive, group != nil else {
            let fallback = MultiThreadedEventLoopGroup.singleton
            return fallback.next().makeFailedFuture(SSHSessionError.notConnected)
        }

        let promise = transport.eventLoop.makePromise(of: Channel.self)
        transport.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                promise.fail(error)
            case .success(let sshHandler):
                sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(SSHSessionError.invalidChannelType)
                    }
                    return initializer(childChannel)
                }
            }
        }
        return promise.futureResult
    }

    // MARK: State helpers

    @MainActor
    private func setState(_ newState: ConnectionState) {
        state = newState
    }

    /// Async accessor for the current connection state.
    var currentState: ConnectionState {
        get async { await MainActor.run { state } }
    }

    private func transportFailed(_ error: Error) {
        Task { await setState(.failed(error.localizedDescription)) }
    }

    private func transportClosed() {
        // Nil the transports out: a closed channel still references its (about
        // to be shut down) event loop, and any late pipeline.handler / execute
        // call on it leaks a promise and crashes.
        transport = nil
        jumpTransport = nil
        Task {
            let current = await state
            if current == .connected || current == .connecting {
                await setState(.closed)
            }
            shutdownGroup()
        }
    }

    private func shutdownGroup() {
        let group = self.group
        self.group = nil
        group?.shutdownGracefully { _ in }
    }
}
