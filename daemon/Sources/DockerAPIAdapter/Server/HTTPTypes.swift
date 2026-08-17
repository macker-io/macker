import Foundation
import NIOCore

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let queryAll: [String: [String]]
    public let headers: [String: String]
    public let body: Data
    /// Set instead of ``body`` for routes whose payload is spooled to disk
    /// (build contexts, image archives). Valid until the response completes.
    public let bodyFile: URL?

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        queryAll: [String: [String]] = [:],
        headers: [String: String] = [:],
        body: Data = Data(),
        bodyFile: URL? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.queryAll = queryAll
        self.headers = headers
        self.body = body
        self.bodyFile = bodyFile
    }
}

/// Chunked HTTP body. `onClose` runs once when the client drops or the stream ends.
public struct HTTPStream: Sendable {
    public let chunks: AsyncStream<ByteBuffer>
    public let onClose: (@Sendable () async -> Void)?

    public init(_ chunks: AsyncStream<ByteBuffer>, onClose: (@Sendable () async -> Void)? = nil) {
        self.chunks = chunks
        self.onClose = onClose
    }
}

public enum HTTPResponseBody: Sendable {
    case none
    case buffer(ByteBuffer)
    case stream(HTTPStream)
    case hijack(DockerHijack)
}

/// Raw TCP or WebSocket session after Docker attach / exec start hijack.
public struct DockerHijack: Sendable {
    public enum Kind: Sendable {
        case tcp
        case websocket
    }

    public let kind: Kind
    public let output: AsyncStream<ByteBuffer>
    public let onStdin: (@Sendable (Data) async -> Void)?
    public let onClose: @Sendable () async -> Void

    public init(
        kind: Kind,
        output: AsyncStream<ByteBuffer>,
        onStdin: (@Sendable (Data) async -> Void)? = nil,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.kind = kind
        self.output = output
        self.onStdin = onStdin
        self.onClose = onClose
    }
}

public struct HTTPResponse: Sendable {
    public let status: UInt
    public let headers: [(String, String)]
    public let body: HTTPResponseBody

    public init(status: UInt, headers: [(String, String)] = [], body: HTTPResponseBody = .none) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
