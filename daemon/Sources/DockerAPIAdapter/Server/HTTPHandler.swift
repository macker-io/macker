import CryptoKit
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// Accumulates one HTTP/1.1 request, then dispatches it to ``Router``.
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private let logger: Logger
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
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
        case .body(var buffer):
            if body == nil {
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
            let request = HTTPRequest(
                method: head.method.rawValue,
                path: parsed.path,
                query: parsed.query,
                queryAll: parsed.queryAll,
                headers: headers,
                body: bodyData
            )
            let router = self.router
            let logger = self.logger
            let channel = context.channel
            let handler = self

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
                handler.writeResponse(channel: channel, request: request, response: response)
                logger.debug("\(request.method) \(request.path) -> \(response.status)")
            }
            self.head = nil
            self.body = nil
        }
    }

    private func writeResponse(channel: Channel, request: HTTPRequest, response: HTTPResponse) {
        guard channel.isActive else { return }

        if case .hijack(let session) = response.body {
            channel.eventLoop.makeFutureWithTask {
                await self.performHijack(channel: channel, request: request, response: response, session: session)
            }.whenFailure { error in
                self.logger.error("hijack failed: \(error)")
                channel.close(promise: nil)
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

        case .buffer(let body):
            if headers["content-length"].isEmpty {
                headers.add(name: "Content-Length", value: "\(body.readableBytes)")
            }
            Self.writeHead(channel: channel, status: response.status, headers: headers)
            if body.readableBytes > 0, request.method.uppercased() != "HEAD" {
                channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
            }
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)

        case .stream(let stream):
            Self.writeHead(channel: channel, status: response.status, headers: headers)
            channel.eventLoop.makeFutureWithTask {
                for await chunk in stream {
                    try await channel.eventLoop.submit {
                        guard channel.isActive else { return }
                        channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(chunk)), promise: nil)
                    }.get()
                }
                try await channel.eventLoop.submit {
                    guard channel.isActive else { return }
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                }.get()
            }.whenFailure { _ in
                channel.close(promise: nil)
            }

        case .hijack:
            break
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
