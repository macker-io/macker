import ContainerEngine
import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix

/// Serves Docker's BuildKit endpoints (`POST /grpc`, `POST /session`, both upgraded to `h2c`)
/// by relaying them to the daemon-managed `buildkitd`.
///
/// With these endpoints present, the official `docker build` / `docker compose build` select
/// buildx's `docker` driver, like against Docker Engine, so results land in the local image
/// store without `--load`. Each upgraded connection gets its own upstream connection
/// (`buildctl dial-stdio` in the builder VM). Streams are relayed frame by frame with reads
/// paced by writes, so neither side buffers without bound.
struct BuildKitProxy: Sendable {
    let engine: EngineManager

    /// HTTP/2 settings for both legs: large windows so contexts and layers move quickly.
    static let window = 4 * 1024 * 1024
    static let settings: [HTTP2Setting] = [
        HTTP2Setting(parameter: .maxConcurrentStreams, value: 1000),
        HTTP2Setting(parameter: .initialWindowSize, value: window),
        HTTP2Setting(parameter: .maxFrameSize, value: 1 << 20),
    ]

    /// `/grpc`: a raw HTTP/2 connection carrying BuildKit's `Control` API.
    func serveGRPC(on channel: Channel) -> EventLoopFuture<Void> {
        let upstream = UpstreamConnection(engine: engine, eventLoop: channel.eventLoop)
        channel.closeFuture.whenComplete { _ in upstream.close() }
        let engine = self.engine
        return channel.configureHTTP2Pipeline(
            mode: .server,
            initialLocalSettings: Self.settings,
            targetWindowSize: Self.window,
            inboundStreamInitializer: { stream in
                stream.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    stream.pipeline.addHandler(ClientStreamRelay(upstream: upstream, engine: engine))
                }
            }
        ).map { _ in
            upstream.onClose { channel.close(promise: nil) }
        }
    }

    /// `/session`: the client's session connection, carried to `buildkitd` inside a
    /// `Control/Session` stream of `BytesMessage`s (what BuildKit's `grpchijack` expects).
    func serveSession(on channel: Channel, headers: [(String, String)]) -> EventLoopFuture<Void> {
        let upstream = UpstreamConnection(engine: engine, eventLoop: channel.eventLoop)
        channel.closeFuture.whenComplete { _ in upstream.close() }
        let raw = SessionRawRelay(upstream: upstream, sessionHeaders: headers)
        return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
            channel.pipeline.addHandler(raw)
        }
    }
}

// MARK: - Upstream connection

/// Lazily dialed HTTP/2 client connection to `buildkitd`. All work happens on one event loop
/// (the client connection's), so relays on both legs never cross threads.
final class UpstreamConnection: @unchecked Sendable {
    private let engine: EngineManager
    let eventLoop: EventLoop
    private var multiplexer: EventLoopFuture<HTTP2StreamMultiplexer>?
    private var channel: Channel?
    private var closed = false
    private var closeCallbacks: [() -> Void] = []

    init(engine: EngineManager, eventLoop: EventLoop) {
        self.engine = engine
        self.eventLoop = eventLoop
    }

    func onClose(_ callback: @escaping () -> Void) {
        eventLoop.assertInEventLoop()
        closeCallbacks.append(callback)
    }

    /// Opens a stream on the upstream connection (dialing it on first use).
    func openStream(_ initializer: @escaping NIOChannelInitializer) -> EventLoopFuture<Channel> {
        eventLoop.assertInEventLoop()
        return connect().flatMap { multiplexer in
            multiplexer.createStreamChannel(initializer)
        }
    }

    func close() {
        eventLoop.execute {
            guard !self.closed else { return }
            self.closed = true
            self.channel?.close(promise: nil)
            let callbacks = self.closeCallbacks
            self.closeCallbacks = []
            callbacks.forEach { $0() }
        }
    }

    private func connect() -> EventLoopFuture<HTTP2StreamMultiplexer> {
        if let multiplexer { return multiplexer }
        let engine = self.engine
        let eventLoop = self.eventLoop
        let dialed = eventLoop.makeFutureWithTask { try await engine.dialBuildKit() }
        let future = dialed.flatMap { fd -> EventLoopFuture<HTTP2StreamMultiplexer> in
            let ready = eventLoop.makePromise(of: HTTP2StreamMultiplexer.self)
            let connected = ClientBootstrap(group: eventLoop)
                .channelInitializer { channel in
                    channel.configureHTTP2Pipeline(
                        mode: .client,
                        initialLocalSettings: BuildKitProxy.settings,
                        targetWindowSize: BuildKitProxy.window,
                        inboundStreamInitializer: nil
                    ).map { ready.succeed($0) }
                }
                .withConnectedSocket(fd)
            connected.whenFailure { ready.fail($0) }
            return connected.flatMap { channel in
                self.channel = channel
                channel.closeFuture.whenComplete { _ in self.close() }
                if self.closed { channel.close(promise: nil) }
                return ready.futureResult
            }
        }
        multiplexer = future
        return future
    }
}

// MARK: - /grpc stream relay

/// State shared by the two halves of one relayed gRPC call.
final class RelayedCall: @unchecked Sendable {
    var path = ""
    var export: BuildKitControl.MobyExport?
    var requestBody = Data()
    var responseBody = Data()

    var isSolve: Bool { path == BuildKitControl.solvePath }
}

/// Client-facing half of a stream: forwards to a new upstream stream; edits `Solve` requests.
final class ClientStreamRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let upstream: UpstreamConnection
    private let engine: EngineManager
    private let call = RelayedCall()
    private var peer: Channel?
    private var context: ChannelHandlerContext?
    private var closed = false

    init(upstream: UpstreamConnection, engine: EngineManager) {
        self.upstream = upstream
        self.engine = engine
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        let own = context.channel
        let call = self.call
        let engine = self.engine
        upstream.openStream { stream in
            stream.pipeline.addHandler(UpstreamStreamRelay(peer: own, call: call, engine: engine))
        }.whenComplete { result in
            switch result {
            case .success(let stream):
                if self.closed {
                    stream.close(promise: nil)
                    return
                }
                self.peer = stream
                context.read()
            case .failure(let error):
                Self.failCall(own, message: "BuildKit is unavailable: \(error)")
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard let peer else { return }
        switch payload {
        case .headers(let headers):
            if call.path.isEmpty {
                call.path = headers.headers.first(name: ":path") ?? ""
                if call.isSolve {
                    let engine = self.engine
                    context.eventLoop.makeFutureWithTask {
                        await engine.beginBuildKitSolve()
                    }.whenSuccess {
                        // The client stream outlives Solve until the local import completes.
                        context.channel.closeFuture.whenComplete { _ in
                            Task { await engine.endBuildKitSolve() }
                        }
                    }
                }
            }
            forward(payload, to: peer, context: context)
        case .data(let frame):
            guard call.isSolve else {
                forward(payload, to: peer, context: context)
                return
            }
            if case .byteBuffer(let buffer) = frame.data {
                call.requestBody.append(contentsOf: buffer.readableBytesView)
            }
            guard frame.endStream else {
                context.read()
                return
            }
            forward(.data(.init(data: .byteBuffer(ByteBuffer(data: rewriteSolve(call.requestBody))), endStream: true)), to: peer, context: context)
        case .rstStream:
            forward(payload, to: peer, context: context)
        default:
            context.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed = true
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func forward(_ payload: HTTP2Frame.FramePayload, to peer: Channel, context: ChannelHandlerContext) {
        peer.writeAndFlush(payload).whenComplete { result in
            if case .failure = result {
                context.close(promise: nil)
                return
            }
            context.read()
        }
    }

    /// `moby` exporter → `image`; remembered so the response can be imported.
    private func rewriteSolve(_ body: Data) -> Data {
        var buffer = body
        var out = Data()
        for message in GRPCFraming.takeMessages(&buffer) {
            guard !message.compressed,
                let rewritten = try? BuildKitControl.rewriteSolveRequest(message.payload)
            else {
                out.append(GRPCFraming.frame(message.payload))
                continue
            }
            if let export = rewritten.export {
                call.export = export
            }
            out.append(GRPCFraming.frame(rewritten.payload))
        }
        out.append(buffer)
        return out
    }

    /// gRPC "trailers-only" error so the client prints the reason.
    static func failCall(_ channel: Channel, message: String, code: Int = 14) {
        var headers = HPACKHeaders()
        headers.add(name: ":status", value: "200")
        headers.add(name: "content-type", value: "application/grpc")
        headers.add(name: "grpc-status", value: String(code))
        headers.add(name: "grpc-message", value: percentEncode(message))
        channel.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true)), promise: nil)
    }

    static func percentEncode(_ message: String) -> String {
        var allowed = CharacterSet(charactersIn: " ")
        allowed.formUnion(.alphanumerics)
        allowed.formUnion(CharacterSet(charactersIn: "-_.~!$&'()*+,;=:@/?"))
        return message.addingPercentEncoding(withAllowedCharacters: allowed) ?? message
    }
}

/// `buildkitd`-facing half: forwards responses; after a rewritten `Solve` succeeds, imports the
/// image into the local store before the client sees the result.
final class UpstreamStreamRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let peer: Channel
    private let call: RelayedCall
    private let engine: EngineManager
    /// Upstream finished the call (trailers or reset); the client side ends itself once the
    /// last frame is written, which may be after an image import.
    private var ended = false

    init(peer: Channel, call: RelayedCall, engine: EngineManager) {
        self.peer = peer
        self.call = call
        self.engine = engine
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Paced: the next frame is read once the client side accepted the previous one.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenSuccess {
            context.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        let intercept = call.isSolve && call.export != nil
        switch payload {
        case .data(let frame) where intercept:
            if case .byteBuffer(let buffer) = frame.data {
                call.responseBody.append(contentsOf: buffer.readableBytesView)
            }
            context.read()
        case .headers(let headers) where intercept && headers.endStream:
            ended = true
            finishSolve(trailers: headers.headers, context: context)
        case .data, .headers, .rstStream:
            if case .rstStream = payload { ended = true }
            if case .headers(let headers) = payload, headers.endStream { ended = true }
            if case .data(let frame) = payload, frame.endStream { ended = true }
            peer.writeAndFlush(payload).whenComplete { result in
                if case .failure = result {
                    context.close(promise: nil)
                    return
                }
                context.read()
            }
        default:
            context.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !ended {
            peer.close(promise: nil)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func finishSolve(trailers: HPACKHeaders, context: ChannelHandlerContext) {
        let peer = self.peer
        let body = call.responseBody
        guard trailers.first(name: "grpc-status") == "0", let export = call.export else {
            Self.send(body: body, trailers: trailers, to: peer)
            return
        }
        var buffer = body
        let messages = GRPCFraming.takeMessages(&buffer)
        guard let message = messages.first, !message.compressed,
            let response = try? BuildKitControl.exporterResponse(message.payload),
            let digest = response["containerimage.digest"]
        else {
            Self.send(body: body, trailers: trailers, to: peer)
            return
        }
        let engine = self.engine
        let names = export.names
        context.eventLoop.makeFutureWithTask {
            try await engine.importBuildKitImage(digest: digest, names: names)
        }.whenComplete { result in
            switch result {
            case .success(let localID):
                var payload = message.payload
                if localID != digest,
                    let rewritten = try? BuildKitControl.rewriteExporterResponse(
                        payload,
                        set: ["containerimage.digest": localID]
                    )
                {
                    payload = rewritten
                }
                Self.send(body: GRPCFraming.frame(payload), trailers: trailers, to: peer)
            case .failure(let error):
                var failed = HPACKHeaders()
                failed.add(name: "grpc-status", value: "2")
                failed.add(
                    name: "grpc-message",
                    value: ClientStreamRelay.percentEncode("failed to load the built image into Macker: \(error)")
                )
                Self.send(body: Data(), trailers: failed, to: peer)
            }
        }
    }

    private static func send(body: Data, trailers: HPACKHeaders, to peer: Channel) {
        if !body.isEmpty {
            peer.write(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(data: body)))), promise: nil)
        }
        peer.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: trailers, endStream: true)), promise: nil)
    }
}

// MARK: - /session bridge

/// Raw session bytes ⇄ `Control/Session` `BytesMessage` stream.
final class SessionRawRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let upstream: UpstreamConnection
    private let sessionHeaders: [(String, String)]
    private var stream: Channel?
    private var inputClosed = false

    init(upstream: UpstreamConnection, sessionHeaders: [(String, String)]) {
        self.upstream = upstream
        self.sessionHeaders = sessionHeaders
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let raw = context.channel
        upstream.onClose { raw.close(promise: nil) }
        upstream.openStream { stream in
            stream.pipeline.addHandler(SessionUpstreamRelay(raw: raw))
        }.flatMap { stream -> EventLoopFuture<Channel> in
            var headers = HPACKHeaders()
            headers.add(name: ":method", value: "POST")
            headers.add(name: ":scheme", value: "http")
            headers.add(name: ":path", value: BuildKitControl.sessionPath)
            headers.add(name: ":authority", value: "buildkitd")
            headers.add(name: "content-type", value: "application/grpc")
            headers.add(name: "te", value: "trailers")
            for (name, value) in self.sessionHeaders where name.hasPrefix("x-docker-expose-session-") {
                headers.add(name: name, value: value)
            }
            return stream.writeAndFlush(HTTP2Frame.FramePayload.headers(.init(headers: headers))).map { stream }
        }.whenComplete { result in
            switch result {
            case .success(let stream):
                self.stream = stream
                context.read()
            case .failure:
                raw.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let stream else { return }
        let framed = GRPCFraming.frame(BuildKitControl.bytesMessage(Data(buffer.readableBytesView)))
        stream.writeAndFlush(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer(data: framed))))).whenComplete { result in
            if case .failure = result {
                context.close(promise: nil)
                return
            }
            context.read()
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            endUpstream()
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        endUpstream()
        stream?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func endUpstream() {
        guard !inputClosed else { return }
        inputClosed = true
        stream?.writeAndFlush(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(ByteBuffer()), endStream: true)), promise: nil)
    }
}

final class SessionUpstreamRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private let raw: Channel
    private var pending = Data()

    init(raw: Channel) {
        self.raw = raw
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Paced manually below: read the next frame once the raw side took the last one.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenSuccess {
            context.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .data(let frame):
            if case .byteBuffer(let buffer) = frame.data {
                pending.append(contentsOf: buffer.readableBytesView)
            }
            var out = Data()
            for message in GRPCFraming.takeMessages(&pending) {
                if let bytes = try? BuildKitControl.bytesMessageData(message.payload) {
                    out.append(bytes)
                }
            }
            if frame.endStream {
                raw.writeAndFlush(ByteBuffer(data: out)).whenComplete { _ in self.raw.close(promise: nil) }
                return
            }
            guard !out.isEmpty else {
                context.read()
                return
            }
            raw.writeAndFlush(ByteBuffer(data: out)).whenComplete { result in
                if case .failure = result {
                    context.close(promise: nil)
                    return
                }
                context.read()
            }
        case .headers(let headers):
            if headers.endStream {
                raw.close(promise: nil)
            } else {
                context.read()
            }
        case .rstStream:
            raw.close(promise: nil)
        default:
            context.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        raw.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
