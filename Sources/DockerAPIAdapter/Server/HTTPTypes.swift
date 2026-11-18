import Foundation
import NIOCore

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let queryAll: [String: [String]]
    public let headers: [String: String]
    /// Every header in arrival order with lowercased names; repeated names are kept
    /// (``headers`` keeps only the last value).
    public let headerList: [(String, String)]
    public let body: Data
    /// Set instead of ``body`` for routes whose payload is spooled to disk
    /// (build contexts, image archives). Valid until the response completes.
    public let bodyFile: URL?
    /// API version the request was made at (path prefix, or the maximum when unversioned).
    /// Set by ``Router`` before dispatch.
    public internal(set) var apiVersion: DockerAPIVersion = .maximum

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        queryAll: [String: [String]] = [:],
        headers: [String: String] = [:],
        headerList: [(String, String)]? = nil,
        body: Data = Data(),
        bodyFile: URL? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.queryAll = queryAll
        self.headers = headers
        self.headerList = headerList ?? headers.map { ($0.key, $0.value) }
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
    /// `101` + `Upgrade: <protocol>`, then the raw connection is handed to `configure`
    /// (on its event loop, HTTP/1 codec already removed). Used for BuildKit's `h2c` endpoints.
    case upgrade(HTTPUpgrade)
}

public struct HTTPUpgrade: Sendable {
    public let protocolName: String
    public let configure: @Sendable (Channel) -> EventLoopFuture<Void>

    public init(protocolName: String, configure: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) {
        self.protocolName = protocolName
        self.configure = configure
    }
}

/// Raw TCP or WebSocket session after Docker attach / exec start hijack.
public struct DockerHijack: Sendable {
    public enum Kind: Sendable {
        case tcp
        case websocket
    }

    public let kind: Kind
    public let output: AsyncStream<ByteBuffer>
    /// Raw stdin bytes from the client, delivered in order.
    public let onStdin: (@Sendable (Data) async -> Void)?
    /// The client half-closed its side (`CloseWrite` after stdin EOF). Delivered after all
    /// preceding stdin bytes.
    public let onStdinClosed: (@Sendable () async -> Void)?
    public let onClose: @Sendable () async -> Void

    public init(
        kind: Kind,
        output: AsyncStream<ByteBuffer>,
        onStdin: (@Sendable (Data) async -> Void)? = nil,
        onStdinClosed: (@Sendable () async -> Void)? = nil,
        onClose: @escaping @Sendable () async -> Void
    ) {
        self.kind = kind
        self.output = output
        self.onStdin = onStdin
        self.onStdinClosed = onStdinClosed
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
