import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHTerminalError: Error, Equatable, Sendable {
    /// Nothing answered at that address and port. Remote Login may be off.
    case unreachable(String)
    /// The server's host key was not the one trusted for this Mac, or the person declined it.
    case hostKeyRejected
    /// The server took neither this device's key nor a password.
    case authenticationFailed
    /// The person was asked for a password and chose not to give one.
    case cancelled
    /// Logged in, but the server would not start a shell in a terminal.
    case shellRefused
    case closed(String)
}

/// One terminal on a Mac: an SSH connection, a pseudo-terminal, and a login shell in it.
///
/// What is typed goes in with `send`, what the shell prints comes out as `events`, and the size of the
/// terminal follows the screen with `resize`. The shell is the user's own, started by the Mac's SSH
/// server after it has authenticated this device; nothing here runs anything on the Mac itself.
public final class SSHTerminal: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case output([UInt8])
        case exitStatus(Int)
        /// The connection is gone. Always the last event.
        case closed
    }

    public struct Options: Sendable {
        public var term: String
        public var columns: Int
        public var rows: Int
        public var connectTimeoutSeconds: Int64

        public init(term: String = "xterm-256color", columns: Int = 80, rows: Int = 24, connectTimeoutSeconds: Int64 = 10) {
            self.term = term
            self.columns = columns
            self.rows = rows
            self.connectTimeoutSeconds = connectTimeoutSeconds
        }
    }

    /// Decides whether to trust the host key the server presented.
    public typealias HostKeyCheck = @Sendable (SSHHostKey) async -> Bool
    /// Asks the person for a password, or returns nil when they decline.
    public typealias PasswordPrompt = @Sendable () async -> String?

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var connection: Channel?
    private var shell: Channel?
    private var finished = false

    public init() {
        var continuation: AsyncStream<Event>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
    }

    /// Connects, authenticates, and starts a login shell in a pseudo-terminal. Returns once the
    /// shell is running; throws `SSHTerminalError` saying why when it cannot get that far.
    ///
    /// Authentication offers this device's key first. Only if the server refuses it, and a
    /// `password` prompt is given, is the person asked for their password.
    public func connect(
        host: String, port: Int, username: String, key: SSHDeviceKey,
        password: PasswordPrompt? = nil, hostKey: @escaping HostKeyCheck, options: Options = Options()
    ) async throws {
        let outcome = Outcome()
        let userAuth = UserAuthentication(username: username, key: key.privateKey, password: password, outcome: outcome)
        let serverAuth = ServerAuthentication(check: hostKey, outcome: outcome)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(options.connectTimeoutSeconds))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(ConnectionErrors(outcome: outcome))
                }
            }

        let connection: Channel
        do {
            connection = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw SSHTerminalError.unreachable("\(host):\(port)")
        }
        lock.withLock { self.connection = connection }
        connection.closeFuture.whenComplete { [weak self] _ in self?.finish() }

        let ready = connection.eventLoop.makePromise(of: Void.self)
        let handler = ShellHandler(options: options, ready: ready) { [weak self] event in self?.emit(event) }
        do {
            let shell = try await connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<Channel> in
                let promise = connection.eventLoop.makePromise(of: Channel.self)
                // SSH opens channels only once authentication has succeeded, so this waits for it.
                ssh.createChannel(promise, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(handler)
                    }
                }
                return promise.futureResult
            }.get()
            lock.withLock { self.shell = shell }
            try await ready.futureResult.get()
        } catch {
            // The handler may never have been added, and a promise left unfulfilled is a leak NIO
            // traps on; finishing it is safe even if the handler already did, since it only counts once.
            connection.eventLoop.execute { handler.abandon(error) }
            connection.close(promise: nil)
            if let known = outcome.error { throw known }
            if let known = error as? SSHTerminalError { throw known }
            throw SSHTerminalError.closed("\(error)")
        }
    }

    /// Sends what was typed. Silently dropped before the shell is running or after it has ended.
    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, let shell = lock.withLock({ self.shell }) else { return }
        var buffer = shell.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        shell.writeAndFlush(buffer, promise: nil)
    }

    public func send(_ text: String) {
        send(Array(text.utf8))
    }

    /// Tells the shell the terminal is now this many characters wide and rows tall.
    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, let shell = lock.withLock({ self.shell }) else { return }
        let change = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)
        shell.triggerUserOutboundEvent(change, promise: nil)
    }

    public func close() {
        lock.withLock { self.connection }?.close(promise: nil)
    }

    private func emit(_ event: Event) {
        continuation.yield(event)
    }

    private func finish() {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        continuation.yield(.closed)
        continuation.finish()
    }
}

/// Why a connection ended before a shell was running, remembered across the several places that
/// can learn it: the two authentication delegates and the pipeline's error handler.
final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: SSHTerminalError?

    var error: SSHTerminalError? { lock.withLock { recorded } }

    func record(_ error: SSHTerminalError) {
        lock.withLock { if recorded == nil { recorded = error } }
    }
}

final class UserAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let key: NIOSSHPrivateKey
    private let password: SSHTerminal.PasswordPrompt?
    private let outcome: Outcome
    private var triedKey = false
    private var triedPassword = false

    init(username: String, key: NIOSSHPrivateKey, password: SSHTerminal.PasswordPrompt?, outcome: Outcome) {
        self.username = username
        self.key = key
        self.password = password
        self.outcome = outcome
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !triedKey, availableMethods.contains(.publicKey) {
            triedKey = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
            return
        }
        if !triedPassword, availableMethods.contains(.password), let password {
            triedPassword = true
            let username = self.username
            let outcome = self.outcome
            Task {
                guard let typed = await password(), !typed.isEmpty else {
                    outcome.record(.cancelled)
                    nextChallengePromise.fail(SSHTerminalError.cancelled)
                    return
                }
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: username, serviceName: "ssh-connection", offer: .password(.init(password: typed))))
            }
            return
        }
        // Failed, not answered with nil: NIOSSH takes "no offer" as "wait", and the connection would
        // sit there until the server's login timeout. A failure reaches the pipeline and closes it.
        outcome.record(.authenticationFailed)
        nextChallengePromise.fail(SSHTerminalError.authenticationFailed)
    }
}

final class ServerAuthentication: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let check: SSHTerminal.HostKeyCheck
    private let outcome: Outcome

    init(check: @escaping SSHTerminal.HostKeyCheck, outcome: Outcome) {
        self.check = check
        self.outcome = outcome
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let check = self.check
        let outcome = self.outcome
        Task {
            if await check(SSHHostKey(hostKey)) {
                validationCompletePromise.succeed(())
            } else {
                outcome.record(.hostKeyRejected)
                validationCompletePromise.fail(SSHTerminalError.hostKeyRejected)
            }
        }
    }
}

/// Closes the connection on any error, remembering it if nothing more specific is known.
final class ConnectionErrors: ChannelInboundHandler {
    typealias InboundIn = Any
    private let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        outcome.record(.closed("\(error)"))
        context.close(promise: nil)
    }
}

/// The session channel: asks for a pseudo-terminal and a shell, then carries bytes both ways.
/// Made before its channel exists and handed to it, then used only on that channel's event loop,
/// which is what makes the unchecked Sendable true.
final class ShellHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let options: SSHTerminal.Options
    private let ready: EventLoopPromise<Void>
    private let emit: (SSHTerminal.Event) -> Void
    private var replies = 0
    private var readyDone = false

    init(options: SSHTerminal.Options, ready: EventLoopPromise<Void>, emit: @escaping (SSHTerminal.Event) -> Void) {
        self.options = options
        self.ready = ready
        self.emit = emit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: options.term,
            terminalCharacterWidth: options.columns, terminalRowHeight: options.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            // One reply for the terminal, one for the shell: both granted means it is running.
            replies += 1
            if replies == 2 { complete(nil) }
        case is ChannelFailureEvent:
            complete(.shellRefused)
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            emit(.exitStatus(status.exitStatus))
        case ChannelEvent.inputClosed:
            // The shell has finished and the server closed its side.
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data, bytes.readableBytes > 0 else { return }
        emit(.output(Array(bytes.readableBytesView)))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.closed("the shell ended before it started"))
        // One terminal per connection: when its shell is gone, so is the reason for the connection.
        context.channel.parent?.close(promise: nil)
        context.fireChannelInactive()
    }

    /// Settles the start-up promise when connecting failed before the shell could. On the event loop.
    func abandon(_ error: Error) {
        complete(error as? SSHTerminalError ?? .closed("\(error)"))
    }

    private func complete(_ error: SSHTerminalError?) {
        guard !readyDone else { return }
        readyDone = true
        if let error { ready.fail(error) } else { ready.succeed(()) }
    }
}
