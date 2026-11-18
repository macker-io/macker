import Darwin
import Foundation

public struct UnixHTTPError: LocalizedError {
    public let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// Blocking HTTP/1.1 primitives for local Engine API clients. Use away from the UI thread.
public struct HTTPReader {
    private let fd: Int32
    private var buffer = Data()

    public init(socketPath: String, timeoutSeconds: Int?) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixHTTPError("failed to create UNIX socket: \(Self.errnoString())")
        }
        self.fd = fd
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))

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
            throw UnixHTTPError("socket path exceeds UNIX address limit: \(socketPath)")
        }
        guard !socketPath.utf8.contains(0) else {
            Darwin.close(fd)
            throw UnixHTTPError("UNIX socket path contains a NUL byte")
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
            throw UnixHTTPError("cannot connect to \(socketPath): \(Self.errnoString())")
        }
    }

    public var socketFD: Int32 { fd }

    public func close() {
        Darwin.close(fd)
    }

    public mutating func takeBuffer() -> Data {
        let data = buffer
        buffer = Data()
        return data
    }

    public func send(
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
    public func send(method: String, path: String, bodyFile: URL, contentType: String) throws {
        guard let handle = try? FileHandle(forReadingFrom: bodyFile),
            let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size]) as? NSNumber
        else {
            throw UnixHTTPError("cannot read request body at \(bodyFile.path)")
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

    public mutating func readHead() throws -> (statusCode: Int, headers: [String: String]) {
        let raw = try readUntil(Data("\r\n\r\n".utf8))
        guard let text = String(data: raw, encoding: .utf8) else {
            throw UnixHTTPError("daemon returned a non-UTF8 response")
        }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else {
            throw UnixHTTPError("daemon returned an empty HTTP response")
        }
        let tokens = statusLine.split(separator: " ")
        guard tokens.count >= 2, let code = Int(tokens[1]) else {
            throw UnixHTTPError("unrecognized HTTP status line: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return (code, headers)
    }

    public mutating func readBody(status: Int, headers: [String: String]) throws -> Data {
        var data = Data()
        try readBodyStreaming(status: status, headers: headers) { data.append($0) }
        return data
    }

    public mutating func readBodyLines(status: Int, headers: [String: String], onLine: (String) -> Void) throws {
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

    public mutating func readBodyStreaming(status: Int, headers: [String: String], onBytes: (Data) throws -> Void) throws {
        if status == 204 || status == 304 {
            return
        }
        if headers["transfer-encoding"]?.localizedCaseInsensitiveContains("chunked") == true {
            try readChunked(onBytes: onBytes)
            return
        }
        if let length = headers["content-length"].flatMap(Int.init) {
            if length > 0 {
                var remaining = length
                while remaining > 0 {
                    let count = min(remaining, 64 * 1024)
                    try onBytes(readExact(count))
                    remaining -= count
                }
            }
            return
        }
        while true {
            if !buffer.isEmpty {
                try onBytes(takeBuffer())
            }
            if try !readMore(allowEOF: true) { break }
        }
    }

    private mutating func readChunked(onBytes: (Data) throws -> Void) throws {
        while true {
            let sizeLine = try readUntil(Data("\r\n".utf8))
            guard let hex = String(data: sizeLine, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ";").first,
                let size = Int(hex, radix: 16), size >= 0
            else {
                throw UnixHTTPError("invalid chunk size")
            }
            if size == 0 {
                _ = try? readUntil(Data("\r\n".utf8))
                break
            }
            try onBytes(readExact(size))
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
                    throw UnixHTTPError("failed to write HTTP request: \(Self.ioError())")
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
            throw UnixHTTPError("connection closed")
        }
        if n < 0 && errno == EINTR { return true }
        if n < 0 {
            throw UnixHTTPError("failed to read HTTP response: \(Self.ioError())")
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
