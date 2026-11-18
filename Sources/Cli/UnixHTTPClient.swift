import Darwin
import Foundation
import MackerTransport

/// HTTP/1.1 client over a UNIX domain socket.
enum UnixHTTPClient {
    struct Response: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    static func get(_ path: String, socketPath: String, timeoutSeconds: Int? = 5) throws -> Response {
        try request(method: "GET", path: path, socketPath: socketPath, timeoutSeconds: timeoutSeconds)
    }

    static func post(_ path: String, socketPath: String, timeoutSeconds: Int? = 5) throws -> Response {
        try request(method: "POST", path: path, socketPath: socketPath, timeoutSeconds: timeoutSeconds)
    }

    static func request(
        method: String,
        path: String,
        socketPath: String,
        body: Data? = nil,
        contentType: String = "application/json",
        timeoutSeconds: Int? = 5
    ) throws -> Response {
        var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: timeoutSeconds)
        defer { reader.close() }
        try reader.send(method: method, path: path, body: body, contentType: contentType)
        let head = try reader.readHead()
        let responseBody: Data
        if method.uppercased() == "HEAD" || head.statusCode == 204 || head.statusCode == 304 {
            responseBody = Data()
        } else {
            responseBody = try reader.readBody(status: head.statusCode, headers: head.headers)
        }
        return Response(statusCode: head.statusCode, headers: head.headers, body: responseBody)
    }

    /// Reads a newline-delimited JSON stream (pull / push / build / events).
    /// `bodyFile` uploads from disk so a large build context never enters memory.
    static func streamLines(
        method: String,
        path: String,
        socketPath: String,
        body: Data? = nil,
        bodyFile: URL? = nil,
        contentType: String = "application/json",
        timeoutSeconds: Int? = 300,
        onLine: (String) -> Void
    ) throws -> Int {
        var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: timeoutSeconds)
        defer { reader.close() }
        if let bodyFile {
            try reader.send(method: method, path: path, bodyFile: bodyFile, contentType: contentType)
        } else {
            try reader.send(method: method, path: path, body: body, contentType: contentType)
        }
        let head = try reader.readHead()
        try reader.readBodyLines(status: head.statusCode, headers: head.headers, onLine: onLine)
        return head.statusCode
    }

    /// Streams raw response bytes (container logs).
    static func streamBytes(
        method: String,
        path: String,
        socketPath: String,
        timeoutSeconds: Int? = 300,
        onBytes: (Data) -> Void
    ) throws -> Int {
        var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: timeoutSeconds)
        defer { reader.close() }
        try reader.send(method: method, path: path, body: nil)
        let head = try reader.readHead()
        if head.statusCode < 400 {
            try reader.readBodyStreaming(status: head.statusCode, headers: head.headers, onBytes: onBytes)
        }
        return head.statusCode
    }

    /// Docker attach / exec start: `Upgrade: tcp`, then bidirectional raw stdio.
    static func hijack(
        method: String,
        path: String,
        socketPath: String,
        body: Data? = nil,
        stdin: Bool,
        tty: Bool,
        resize: ((Int, Int) -> Void)? = nil,
        onUpgraded: (() -> Void)? = nil,
        detachKeys: [UInt8]? = nil
    ) throws {
        var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: nil)
        var restoreTTY: (() -> Void)?
        var winch: DispatchSourceSignal?
        defer {
            winch?.cancel()
            restoreTTY?()
            reader.close()
        }
        try reader.send(
            method: method,
            path: path,
            body: body,
            extraHeaders: ["Connection": "Upgrade", "Upgrade": "tcp"],
            closeConnection: false
        )
        let head = try reader.readHead()
        if head.statusCode >= 400 {
            let errorBody = try reader.readBody(status: head.statusCode, headers: head.headers)
            if let error = try? JSONDecoder().decode(HijackError.self, from: errorBody) {
                throw CLIError.http(error.message)
            }
            if let text = String(data: errorBody, encoding: .utf8), !text.isEmpty {
                throw CLIError.http(text)
            }
            throw CLIError.http("HTTP \(head.statusCode)")
        }

        let raw = tty && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        if raw {
            restoreTTY = TerminalIO.makeRaw()
        }
        onUpgraded?()

        let fd = reader.socketFD
        if stdin {
            HijackIO.copyStdin(to: fd, detachKeys: detachKeys)
        }

        if tty, let resize {
            winch = TerminalIO.watchResize(resize)
            if let size = TerminalIO.windowSize() {
                resize(size.height, size.width)
            }
        }

        var pending = Data()
        let leftover = reader.takeBuffer()
        if !leftover.isEmpty {
            HijackIO.writeOutput(leftover, tty: tty, pending: &pending)
        }
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = tmp.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n == 0 { break }
            if n < 0 && errno == EINTR { continue }
            if n < 0 { break }
            HijackIO.writeOutput(Data(tmp.prefix(n)), tty: tty, pending: &pending)
        }
    }
}

private struct HijackError: Decodable {
    var message: String
}
