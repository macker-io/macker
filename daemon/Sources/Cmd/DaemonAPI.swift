import ArgumentParser
import ContainerEngine
import Darwin
import Foundation

enum Invocation {
    /// `docker` when the binary is invoked via a docker symlink; otherwise `macker`.
    static var commandName: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "docker" ? "docker" : "macker"
    }
}

/// Thin Docker Engine API client over the Macker UNIX socket.
enum DaemonAPI {
    static let apiVersion = "1.41"
    static let clientVersion = ProductVersion.current
    static var socket: String { DaemonPaths.socketPath() }

    static func get(_ path: String, timeoutSeconds: Int? = 5) throws -> UnixHTTPClient.Response {
        try UnixHTTPClient.request(method: "GET", path: prefixed(path), socketPath: socket, timeoutSeconds: timeoutSeconds)
    }

    static func post(
        _ path: String,
        body: Data? = nil,
        contentType: String = "application/json",
        timeoutSeconds: Int? = 5
    ) throws -> UnixHTTPClient.Response {
        try UnixHTTPClient.request(
            method: "POST",
            path: prefixed(path),
            socketPath: socket,
            body: body,
            contentType: contentType,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func delete(_ path: String) throws -> UnixHTTPClient.Response {
        try UnixHTTPClient.request(method: "DELETE", path: prefixed(path), socketPath: socket)
    }

    @discardableResult
    static func requireOK(_ response: UnixHTTPClient.Response) throws -> UnixHTTPClient.Response {
        guard response.statusCode >= 400 else { return response }
        if let error = try? JSONDecoder().decode(APIError.self, from: response.body) {
            throw CLIError.http(error.message)
        }
        if let text = String(data: response.body, encoding: .utf8), !text.isEmpty {
            throw CLIError.http(text)
        }
        throw CLIError.http("HTTP \(response.statusCode)")
    }

    static func decode<T: Decodable>(_ type: T.Type, from response: UnixHTTPClient.Response) throws -> T {
        try JSONDecoder().decode(type, from: try requireOK(response).body)
    }

    static func streamLines(
        method: String,
        path: String,
        timeoutSeconds: Int? = 300,
        onLine: (String) -> Void
    ) throws -> Int {
        try UnixHTTPClient.streamLines(
            method: method,
            path: prefixed(path),
            socketPath: socket,
            timeoutSeconds: timeoutSeconds,
            onLine: onLine
        )
    }

    static func streamBytes(
        method: String,
        path: String,
        timeoutSeconds: Int? = 300,
        onBytes: (Data) -> Void
    ) throws -> Int {
        try UnixHTTPClient.streamBytes(
            method: method,
            path: prefixed(path),
            socketPath: socket,
            timeoutSeconds: timeoutSeconds,
            onBytes: onBytes
        )
    }

    static func hijack(
        path: String,
        method: String = "POST",
        body: Data? = nil,
        stdin: Bool,
        tty: Bool,
        resizePath: String? = nil,
        onUpgraded: (() -> Void)? = nil,
        detachKeys: [UInt8]? = nil
    ) throws {
        let resize: ((Int, Int) -> Void)?
        if let resizePath {
            resize = { height, width in
                _ = try? post("\(resizePath)?h=\(height)&w=\(width)")
            }
        } else {
            resize = nil
        }
        try UnixHTTPClient.hijack(
            method: method,
            path: prefixed(path),
            socketPath: socket,
            body: body,
            stdin: stdin,
            tty: tty,
            resize: resize,
            onUpgraded: onUpgraded,
            detachKeys: detachKeys
        )
    }

    /// Docker CLI-shaped daemon errors (`Error response from daemon: …`).
    static func exitWithDaemonError(_ error: Error) throws -> Never {
        if let code = error as? ExitCode {
            throw code
        }
        var text = error.localizedDescription
        let prefix = "Error response from daemon: "
        if !text.hasPrefix(prefix) {
            text = prefix + text
        }
        fputs("\(text)\n", stderr)
        throw ExitCode(1)
    }

    /// Pull/push NDJSON progress. Throws if the stream reports an error line or a non-200 status.
    static func streamProgress(method: String = "POST", path: String) throws {
        let printer = ProgressPrinter()
        var failed: String?
        let status = try streamLines(method: method, path: path) { line in
            if let message = progressError(in: line) {
                printer.finish()
                failed = message
                fputs("Error: \(message)\n", stderr)
                return
            }
            printer.write(line)
        }
        printer.finish()
        if let failed {
            throw CLIError.http(failed)
        }
        if status != 200 {
            throw CLIError.http("request failed with HTTP \(status)")
        }
    }

    static func isMissingImage(_ response: UnixHTTPClient.Response) -> Bool {
        guard response.statusCode == 404 else { return false }
        let message: String
        if let error = try? JSONDecoder().decode(APIError.self, from: response.body) {
            message = error.message
        } else if let text = String(data: response.body, encoding: .utf8) {
            message = text
        } else {
            return false
        }
        return message.range(of: "no such image", options: .caseInsensitive) != nil
    }

    static func query(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    static func printJSON(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if let text = String(data: pretty, encoding: .utf8) {
            print(text)
        }
    }

    static func splitReference(_ raw: String) -> (name: String, tag: String) {
        if let at = raw.lastIndex(of: "@") {
            return (String(raw[..<at]), String(raw[raw.index(after: at)...]))
        }
        let lastComponent: Substring
        if let slash = raw.lastIndex(of: "/") {
            lastComponent = raw[raw.index(after: slash)...]
        } else {
            lastComponent = raw[...]
        }
        if let colon = lastComponent.lastIndex(of: ":") {
            return (String(raw[..<colon]), String(raw[raw.index(after: colon)...]))
        }
        return (raw, "latest")
    }

    static func parseBytes(_ raw: String) throws -> Int64 {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixes: [(String, Int64)] = [
            ("gb", 1_073_741_824), ("g", 1_073_741_824),
            ("mb", 1_048_576), ("m", 1_048_576),
            ("kb", 1024), ("k", 1024),
            ("b", 1),
        ]
        for (suffix, multiplier) in suffixes where lower.hasSuffix(suffix) {
            let number = String(lower.dropLast(suffix.count))
            guard let value = Double(number) else {
                throw CLIError.io("invalid size: \(raw)")
            }
            return Int64(value * Double(multiplier))
        }
        guard let value = Int64(lower) else {
            throw CLIError.io("invalid size: \(raw)")
        }
        return value
    }

    private static func prefixed(_ path: String) -> String {
        if path.hasPrefix("/v1.") || path == "/_ping" { return path }
        return "/v\(apiVersion)\(path)"
    }

    private static func progressError(in line: String) -> String? {
        let data = Data(line.utf8)
        if let progress = try? JSONDecoder().decode(ProgressLine.self, from: data),
            let error = progress.error, !error.isEmpty
        {
            return error
        }
        if let error = try? JSONDecoder().decode(APIError.self, from: data) {
            return error.message
        }
        return nil
    }

}

/// Rewrites the current TTY line for layer download bars; status lines still get a newline.
private final class ProgressPrinter: @unchecked Sendable {
    private let tty = isatty(STDOUT_FILENO) != 0
    private var dirty = false

    func write(_ line: String) {
        guard let progress = try? JSONDecoder().decode(ProgressLine.self, from: Data(line.utf8)) else { return }
        if let bar = progress.progress {
            let text = "\(progress.id.map { "\($0): " } ?? "")\(progress.status ?? "Downloading") \(bar)"
            if tty {
                fputs("\r\(text)\u{001B}[K", stdout)
                fflush(stdout)
                dirty = true
            }
            return
        }
        guard let text = progress.status else { return }
        finish()
        let rendered = progress.id.map { "\($0): \(text)" } ?? text
        fputs("\(rendered)\n", stdout)
        fflush(stdout)
    }

    func finish() {
        guard dirty else { return }
        fputs("\n", stdout)
        fflush(stdout)
        dirty = false
    }
}

enum Prompt {
    static func confirm(_ warning: String, force: Bool) -> Bool {
        if force { return true }
        print("WARNING! \(warning)")
        print("Are you sure you want to continue? [y/N]")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }
}

enum DockerLog {
    /// Prints Docker multiplexed log frames, or raw text if the payload is not framed.
    static func write(_ data: Data, to file: FileHandle = .standardOutput) {
        var offset = 0
        let bytes = [UInt8](data)
        var framed = false
        while offset + 8 <= bytes.count {
            let stream = bytes[offset]
            let size =
                (Int(bytes[offset + 4]) << 24)
                | (Int(bytes[offset + 5]) << 16)
                | (Int(bytes[offset + 6]) << 8)
                | Int(bytes[offset + 7])
            guard stream <= 2, bytes[offset + 1] == 0, bytes[offset + 2] == 0, bytes[offset + 3] == 0,
                size >= 0, offset + 8 + size <= bytes.count
            else {
                break
            }
            framed = true
            try? file.write(contentsOf: Data(bytes[(offset + 8)..<(offset + 8 + size)]))
            offset += 8 + size
        }
        if !framed, !data.isEmpty {
            try? file.write(contentsOf: data)
        }
    }
}

private struct ProgressLine: Decodable {
    var status: String?
    var id: String?
    var progress: String?
    var error: String?
}

private struct APIError: Decodable {
    var message: String
}
