import Darwin
import Foundation

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

private struct HTTPReader {
    private let fd: Int32
    private var buffer = Data()

    init(socketPath: String, timeoutSeconds: Int?) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.http("failed to create UNIX socket: \(Self.errnoString())")
        }
        self.fd = fd

        if let timeoutSeconds, timeoutSeconds > 0 {
            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= pathLimit else {
            Darwin.close(fd)
            throw CLIError.http("socket path exceeds UNIX address limit: \(socketPath)")
        }
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyBytes(from: UnsafeRawBufferPointer(start: src, count: socketPath.utf8.count + 1))
            }
        }

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw CLIError.http("cannot connect to \(socketPath): \(Self.errnoString())")
        }
    }

    var socketFD: Int32 { fd }

    func close() {
        Darwin.close(fd)
    }

    mutating func takeBuffer() -> Data {
        let data = buffer
        buffer = Data()
        return data
    }

    func send(
        method: String,
        path: String,
        body: Data?,
        contentType: String = "application/json",
        extraHeaders: [String: String] = [:],
        closeConnection: Bool = true
    ) throws {
        var header = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        if closeConnection && extraHeaders.keys.contains(where: { $0.lowercased() == "connection" }) == false {
            header += "Connection: close\r\n"
        }
        if let body {
            header += "Content-Type: \(contentType)\r\n"
            header += "Content-Length: \(body.count)\r\n"
        }
        for (name, value) in extraHeaders {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        try writeAll(Data(header.utf8))
        if let body {
            try writeAll(body)
        }
    }

    /// Same as ``send(method:path:body:contentType:extraHeaders:closeConnection:)``
    /// but reads the request body off disk in chunks.
    func send(method: String, path: String, bodyFile: URL, contentType: String) throws {
        guard let handle = try? FileHandle(forReadingFrom: bodyFile),
            let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size]) as? NSNumber
        else {
            throw CLIError.io("cannot read request body at \(bodyFile.path)")
        }
        defer { try? handle.close() }
        var header = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(size.intValue)\r\n\r\n"
        try writeAll(Data(header.utf8))
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writeAll(chunk)
        }
    }

    mutating func readHead() throws -> (statusCode: Int, headers: [String: String]) {
        let raw = try readUntil(Data("\r\n\r\n".utf8))
        guard let text = String(data: raw, encoding: .utf8) else {
            throw CLIError.http("daemon returned a non-UTF8 response")
        }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else {
            throw CLIError.http("daemon returned an empty HTTP response")
        }
        let tokens = statusLine.split(separator: " ")
        guard tokens.count >= 2, let code = Int(tokens[1]) else {
            throw CLIError.http("unrecognized HTTP status line: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return (code, headers)
    }

    mutating func readBody(status: Int, headers: [String: String]) throws -> Data {
        var data = Data()
        try readBodyStreaming(status: status, headers: headers) { data.append($0) }
        return data
    }

    mutating func readBodyLines(status: Int, headers: [String: String], onLine: (String) -> Void) throws {
        var pending = Data()
        try readBodyStreaming(status: status, headers: headers) { chunk in
            pending.append(chunk)
            while let range = pending.range(of: Data("\n".utf8)) {
                let line = pending[..<range.lowerBound]
                pending.removeSubrange(..<range.upperBound)
                if let text = String(data: line, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onLine(trimmed) }
                }
            }
        }
        if !pending.isEmpty, let text = String(data: pending, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onLine(trimmed) }
        }
    }

    mutating func readBodyStreaming(status: Int, headers: [String: String], onBytes: (Data) -> Void) throws {
        if status == 204 || status == 304 {
            return
        }
        if headers["transfer-encoding"]?.localizedCaseInsensitiveContains("chunked") == true {
            try readChunked(onBytes: onBytes)
            return
        }
        if let length = headers["content-length"].flatMap(Int.init) {
            if length > 0 {
                onBytes(try readExact(length))
            }
            return
        }
        while true {
            if try !readMore(allowEOF: true) { break }
            if !buffer.isEmpty {
                onBytes(buffer)
                buffer = Data()
            }
        }
    }

    private mutating func readChunked(onBytes: (Data) -> Void) throws {
        while true {
            let sizeLine = try readUntil(Data("\r\n".utf8))
            guard let hex = String(data: sizeLine, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ";").first,
                let size = Int(hex, radix: 16)
            else {
                throw CLIError.http("invalid chunk size")
            }
            if size == 0 {
                _ = try? readUntil(Data("\r\n".utf8))
                break
            }
            onBytes(try readExact(size))
            _ = try readUntil(Data("\r\n".utf8))
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            guard let base = raw.baseAddress else { return }
            while written < total {
                let n = Darwin.write(fd, base + written, total - written)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 {
                    throw CLIError.http("failed to write HTTP request: \(Self.ioError())")
                }
                written += n
            }
        }
    }

    private mutating func readUntil(_ marker: Data) throws -> Data {
        while true {
            if let range = buffer.range(of: marker) {
                let result = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                return result
            }
            try readMore(allowEOF: false)
        }
    }

    private mutating func readExact(_ count: Int) throws -> Data {
        while buffer.count < count {
            try readMore(allowEOF: false)
        }
        let result = Data(buffer.prefix(count))
        buffer.removeSubrange(..<count)
        return result
    }

    @discardableResult
    private mutating func readMore(allowEOF: Bool) throws -> Bool {
        var tmp = [UInt8](repeating: 0, count: 4096)
        let n = tmp.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if n == 0 {
            if allowEOF { return false }
            throw CLIError.http("connection closed")
        }
        if n < 0 && errno == EINTR { return true }
        if n < 0 {
            throw CLIError.http("failed to read HTTP response: \(Self.ioError())")
        }
        buffer.append(contentsOf: tmp.prefix(n))
        return true
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }

    private static func ioError() -> String {
        switch errno {
        case EAGAIN, EWOULDBLOCK, ETIMEDOUT:
            return "timed out waiting for the daemon"
        default:
            return errnoString()
        }
    }
}
