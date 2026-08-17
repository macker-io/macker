import CryptoKit
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOWebSocket
import struct os.OSAllocatedUnfairLock

/// Accumulates one HTTP/1.1 request, then dispatches it to ``Router``.
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private let logger: Logger
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var spool: BodySpool?
    private var hijacked = false

    init(router: Router, logger: Logger) {
        self.router = router
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if hijacked { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.body = nil
            self.spool?.discard()
            self.spool = Self.spoolsBody(method: head.method.rawValue, uri: head.uri) ? BodySpool() : nil
        case .body(var buffer):
            if let spool {
                spool.write(buffer)
            } else if body == nil {
                body = buffer
            } else {
                body!.writeBuffer(&buffer)
            }
        case .end:
            guard let head else { return }
            let parsed = Self.parseURI(head.uri)
            let bodyData = body.map { Data($0.readableBytesView) } ?? Data()
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                headers[name.lowercased()] = value
            }
            let spool = self.spool
            spool?.finish()
            let request = HTTPRequest(
                method: head.method.rawValue,
                path: parsed.path,
                query: parsed.query,
                queryAll: parsed.queryAll,
                headers: headers,
                body: bodyData,
                bodyFile: spool?.readableURL
            )
            let router = self.router
            let logger = self.logger
            let channel = context.channel
            let handler = self
            let cleanup: (@Sendable () -> Void)? = spool.flatMap { spool -> (@Sendable () -> Void) in
                { spool.discard() }
            }

            context.eventLoop.makeFutureWithTask {
                await router.handle(request)
            }.whenComplete { result in
                let response: HTTPResponse
                switch result {
                case .success(let value):
                    response = value
                case .failure(let error):
                    logger.error("router failed: \(error)")
                    response = HTTPResponse(
                        status: 500,
                        headers: [("Content-Type", "application/json")],
                        body: .buffer(JSONBody.encode(DockerErrorResponse(message: "internal server error")))
                    )
                }
                if case .hijack = response.body {
                    handler.hijacked = true
                }
                handler.writeResponse(channel: channel, request: request, response: response, cleanup: cleanup)
                logger.debug("\(request.method) \(request.path) -> \(response.status)")
            }
            self.head = nil
            self.body = nil
            self.spool = nil
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        spool?.discard()
        spool = nil
    }

    /// Routes whose request body is a tar and can be arbitrarily large.
    private static func spoolsBody(method: String, uri: String) -> Bool {
        guard method.uppercased() == "POST" else { return false }
        let path = Self.parseURI(uri).path
        let unversioned = Router.splitAPIVersion(path).path
        return unversioned == "/build" || unversioned == "/images/load"
    }

    private func writeResponse(
        channel: Channel,
        request: HTTPRequest,
        response: HTTPResponse,
        cleanup: (@Sendable () -> Void)? = nil
    ) {
        if case .hijack(let session) = response.body {
            guard channel.isActive else {
                Task { await session.onClose() }
                cleanup?()
                return
            }
            channel.eventLoop.makeFutureWithTask {
                await self.performHijack(channel: channel, request: request, response: response, session: session)
                cleanup?()
            }.whenFailure { error in
                self.logger.error("hijack failed: \(error)")
                channel.close(promise: nil)
                cleanup?()
            }
            return
        }

        guard channel.isActive else {
            if case .stream(let stream) = response.body {
                OnceClose(stream.onClose, then: cleanup).run()
            } else {
                cleanup?()
            }
            return
        }

        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }

        switch response.body {
        case .none:
            if headers["content-length"].isEmpty {
                headers.add(name: "Content-Length", value: "0")
            }
            Self.writeHead(channel: channel, status: response.status, headers: headers)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            cleanup?()

        case .buffer(let body):
            if headers["content-length"].isEmpty {
                headers.add(name: "Content-Length", value: "\(body.readableBytes)")
            }
            Self.writeHead(channel: channel, status: response.status, headers: headers)
            if body.readableBytes > 0, request.method.uppercased() != "HEAD" {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
            }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
            cleanup?()

        case .stream(let stream):
            Self.writeHead(channel: channel, status: response.status, headers: headers)
            let close = OnceClose(stream.onClose, then: cleanup)
            channel.closeFuture.whenComplete { _ in
                close.run()
            }
            channel.eventLoop.makeFutureWithTask {
                for await chunk in stream.chunks {
                    let wrote = try await channel.eventLoop.submit {
                        guard channel.isActive else { return false }
                        channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(chunk)), promise: nil)
                        return true
                    }.get()
                    if !wrote { break }
                }
                try await channel.eventLoop.submit {
                    guard channel.isActive else { return }
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                }.get()
                await close.runAwait()
            }.whenFailure { _ in
                channel.close(promise: nil)
                close.run()
            }

        case .hijack:
            cleanup?()
        }
    }

    private func performHijack(
        channel: Channel,
        request: HTTPRequest,
        response: HTTPResponse,
        session: DockerHijack
    ) async {
        var headers = response.headers
        if session.kind == .websocket {
            guard let key = request.headers["sec-websocket-key"], !key.isEmpty else {
                do {
                    try await channel.eventLoop.submit {
                        Self.stripHTTPCodec(channel: channel, httpHandler: self)
                        Self.writeRawHTTP(
                            channel: channel,
                            statusLine: "HTTP/1.1 400 Bad Request",
                            headers: [("Content-Type", "application/json")]
                        )
                        var buffer = channel.allocator.buffer(capacity: 64)
                        buffer.writeString("{\"message\":\"missing Sec-WebSocket-Key\"}")
                        channel.writeAndFlush(buffer, promise: nil)
                        channel.close(promise: nil)
                    }.get()
                } catch {
                    channel.close(promise: nil)
                }
                await session.onClose()
                return
            }
            headers = [
                ("Upgrade", "websocket"),
                ("Connection", "Upgrade"),
                ("Sec-WebSocket-Accept", Self.webSocketAccept(for: key)),
            ]
        }

        let statusLine: String
        switch response.status {
        case 101:
            statusLine = session.kind == .websocket ? "HTTP/1.1 101 Switching Protocols" : "HTTP/1.1 101 UPGRADED"
        default:
            statusLine = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(response.status))"
        }

        let hijackHeaders = headers
        do {
            try await channel.eventLoop.submit {
                Self.stripHTTPCodec(channel: channel, httpHandler: self)
                Self.writeRawHTTP(channel: channel, statusLine: statusLine, headers: hijackHeaders)
                switch session.kind {
                case .tcp:
                    try channel.pipeline.syncOperations.addHandler(TCPHijackHandler(session: session))
                case .websocket:
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(WebSocketFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
                    try channel.pipeline.syncOperations.addHandler(AttachWebSocketHandler(session: session))
                }
            }.get()
        } catch {
            logger.error("hijack setup failed: \(error)")
            channel.close(promise: nil)
            await session.onClose()
        }
    }

    /// Must run on the channel event loop. Non-Sendable HTTP handlers cannot cross isolation.
    private static func stripHTTPCodec(channel: Channel, httpHandler: HTTPHandler) {
        let sync = channel.pipeline.syncOperations
        func remove<H: RemovableChannelHandler>(_ type: H.Type) {
            guard let handler = try? sync.handler(type: type) else { return }
            _ = sync.removeHandler(handler)
        }
        remove(HTTPServerPipelineHandler.self)
        remove(HTTPServerProtocolErrorHandler.self)
        remove(NIOHTTPResponseHeadersValidator.self)
        remove(ByteToMessageHandler<HTTPRequestDecoder>.self)
        remove(HTTPResponseEncoder.self)
        _ = sync.removeHandler(httpHandler)
    }

    private static func writeRawHTTP(channel: Channel, statusLine: String, headers: [(String, String)]) {
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString(statusLine)
        buffer.writeString("\r\n")
        for (name, value) in headers {
            buffer.writeString("\(name): \(value)\r\n")
        }
        buffer.writeString("\r\n")
        channel.writeAndFlush(buffer, promise: nil)
    }

    private static func webSocketAccept(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func reasonPhrase(_ status: UInt) -> String {
        HTTPResponseStatus(statusCode: Int(status)).reasonPhrase
    }

    private static func writeHead(channel: Channel, status: UInt, headers: HTTPHeaders) {
        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: Int(status)),
            headers: headers
        )
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
    }

    static func parseURI(_ uri: String) -> (path: String, query: [String: String], queryAll: [String: [String]]) {
        guard let question = uri.firstIndex(of: "?") else {
            return (uri, [:], [:])
        }
        let path = String(uri[..<question])
        let queryString = String(uri[uri.index(after: question)...])
        var query: [String: String] = [:]
        var queryAll: [String: [String]] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count == 2 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            query[key] = value
            queryAll[key, default: []].append(value)
        }
        return (path, query, queryAll)
    }
}

/// Runs an optional async closer at most once (client drop, write failure, or stream end).
private final class OnceClose: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    private let action: (@Sendable () async -> Void)?
    private let then: (@Sendable () -> Void)?

    init(_ action: (@Sendable () async -> Void)?, then: (@Sendable () -> Void)? = nil) {
        self.action = action
        self.then = then
    }

    func run() {
        Task { await runAwait() }
    }

    func runAwait() async {
        let first = lock.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard first else { return }
        await action?()
        then?()
    }
}

/// Spools a request body to a temp file so the daemon never holds a whole tar in memory.
/// The file lives until the response finishes; the router reads it via ``HTTPRequest/bodyFile``.
private final class BodySpool: @unchecked Sendable {
    private let directory: URL
    private let url: URL
    private var handle: FileHandle?
    private var usable: Bool

    init() {
        let fm = FileManager.default
        directory = fm.temporaryDirectory.appendingPathComponent("macker-body-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("body")
        usable = (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
            && fm.createFile(atPath: url.path, contents: nil)
        handle = usable ? try? FileHandle(forWritingTo: url) : nil
        usable = handle != nil
    }

    /// `nil` when spooling failed, so the route falls back to an empty in-memory body.
    var readableURL: URL? { usable ? url : nil }

    func write(_ buffer: ByteBuffer) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: Data(buffer.readableBytesView))
        } catch {
            usable = false
            try? handle.close()
            self.handle = nil
        }
    }

    func finish() {
        try? handle?.close()
        handle = nil
    }

    func discard() {
        finish()
        try? FileManager.default.removeItem(at: directory)
    }
}
