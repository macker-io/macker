import Foundation
import NIOCore

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let queryAll: [String: [String]]
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        queryAll: [String: [String]] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.queryAll = queryAll
        self.headers = headers
        self.body = body
    }
}

public enum HTTPResponseBody: Sendable {
    case none
    case buffer(ByteBuffer)
    case stream(AsyncStream<ByteBuffer>)
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
