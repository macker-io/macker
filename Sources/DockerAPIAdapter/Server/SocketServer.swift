import ContainerEngine
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import os

/// HTTP/1.1 server bound to a UNIX domain socket (Docker Engine API transport).
public final class SocketServer: @unchecked Sendable {
    public static var defaultSocketPath: String { DaemonPaths.defaultSocketPath }

    private let socketPath: String
    private let router: Router
    private let logger: Logging.Logger
    private let group: MultiThreadedEventLoopGroup
    private let boundChannel = OSAllocatedUnfairLock<(any Channel)?>(uncheckedState: nil)

    public init(
        socketPath: String = defaultSocketPath,
        engine: EngineManager,
        logger: Logging.Logger
    ) {
        self.socketPath = socketPath
        self.router = Router(engine: engine)
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    /// Binds the socket and blocks until the channel is closed (SIGINT/SIGTERM or ``stop()``).
    public func start() async throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // The daemon holds ``DaemonInstanceLock`` before constructing this server, so only
        // one process may remove a stale socket left by a crash.
        try? FileManager.default.removeItem(atPath: socketPath)

        let router = self.router
        let logger = self.logger
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Hijacked attach/exec streams signal stdin EOF with a write-side shutdown;
            // the connection must stay open for the remaining output.
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: true,
                    withErrorHandling: true,
                    withOutboundHeaderValidation: false
                ).flatMap {
                    channel.pipeline.addHandler(HTTPHandler(router: router, logger: logger))
                }
            }

        let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        boundChannel.withLockUnchecked { $0 = channel }

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o660))],
            ofItemAtPath: socketPath
        )
        logger.info("listening on unix://\(socketPath)")

        try await channel.closeFuture.get()
    }

    /// Closes the listener, shuts down the event loop group, and unlinks the socket file.
    public func stop() async {
        let channel = boundChannel.withLockUnchecked { current -> (any Channel)? in
            let value = current
            current = nil
            return value
        }

        if let channel, channel.isActive {
            try? await channel.close().get()
        }
        try? await group.shutdownGracefully()
        try? FileManager.default.removeItem(atPath: socketPath)
        logger.info("socket server stopped")
    }
}
