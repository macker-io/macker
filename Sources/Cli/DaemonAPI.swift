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
    // Before 1.42, pruning without an "all" filter also deletes named volumes.
    static let volumePrunePath = "/v1.42/volumes/prune"
    static let clientVersion = ProductVersion.current
    static func socket() throws -> String {
        try DockerGlobalFlags.socketPath()
    }

    static func get(_ path: String, timeoutSeconds: Int? = 5) throws -> UnixHTTPClient.Response {
        try UnixHTTPClient.request(method: "GET", path: prefixed(path), socketPath: try socket(), timeoutSeconds: timeoutSeconds)
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
            socketPath: try socket(),
            body: body,
            contentType: contentType,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func delete(_ path: String) throws -> UnixHTTPClient.Response {
        try UnixHTTPClient.request(method: "DELETE", path: prefixed(path), socketPath: try socket())
    }

    static func head(_ path: String, timeoutSeconds: Int? = 5) throws -> UnixHTTPClient.Response {
        try UnixHTTPClient.request(method: "HEAD", path: prefixed(path), socketPath: try socket(), timeoutSeconds: timeoutSeconds)
    }

    static func put(
        _ path: String,
        body: Data? = nil,
        contentType: String = "application/x-tar",
        timeoutSeconds: Int? = 5
    ) throws -> UnixHTTPClient.Response {
        try UnixHTTPClient.request(
            method: "PUT",
            path: prefixed(path),
            socketPath: try socket(),
            body: body,
            contentType: contentType,
            timeoutSeconds: timeoutSeconds
        )
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
        bodyFile: URL? = nil,
        contentType: String = "application/json",
        timeoutSeconds: Int? = 300,
        onLine: (String) -> Void
    ) throws -> Int {
        try UnixHTTPClient.streamLines(
            method: method,
            path: prefixed(path),
            socketPath: try socket(),
            bodyFile: bodyFile,
            contentType: contentType,
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
            socketPath: try socket(),
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
            socketPath: try socket(),
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

    /// Pull/push/import NDJSON progress. Throws if the stream reports an error line or a non-200 status.
    /// Quiet mode swallows progress and returns Docker's quiet-mode tokens (pull: references, push: digests).
    enum QuietProgress {
        case off
        case pull
        case push
    }

    @discardableResult
    static func streamProgress(
        method: String = "POST",
        path: String,
        bodyFile: URL? = nil,
        contentType: String = "application/json",
        quiet: QuietProgress = .off
    ) throws -> [String] {
        let printer = ProgressPrinter()
        var failed: String?
        var captured: [String] = []
        let status = try streamLines(
            method: method,
            path: path,
            bodyFile: bodyFile,
            contentType: contentType
        ) { line in
            if let message = progressError(in: line) {
                printer.finish()
                failed = message
                return
            }
            if quiet != .off {
                if let token = quietToken(in: line, capturing: quiet), !captured.contains(token) {
                    captured.append(token)
                }
                return
            }
            printer.write(line)
        }
        printer.finish()
        if let failed {
            try exitWithDaemonError(CLIError.http(failed))
        }
        if status != 200 {
            try exitWithDaemonError(CLIError.http("request failed with HTTP \(status)"))
        }
        return captured
    }

    /// Pull `-q` prints `Status: Downloaded newer image for <ref>`; push `-q` prints `Digest: sha256:…`.
    private static func quietToken(in line: String, capturing: QuietProgress) -> String? {
        guard let progress = try? JSONDecoder().decode(ProgressLine.self, from: Data(line.utf8)),
            let status = progress.status
        else { return nil }
        switch capturing {
        case .off:
            return nil
        case .pull:
            let marker = "Downloaded newer image for "
            guard let range = status.range(of: marker) else { return nil }
            let reference = status[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return reference.isEmpty ? nil : reference
        case .push:
            let marker = "Digest: "
            guard status.hasPrefix(marker) else { return nil }
            let digest = status.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return digest.isEmpty ? nil : String(digest)
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

    /// `key=value` pairs to the daemon's `filters` JSON (`{"key":["value"]}`).
    static func filtersJSON(_ filters: [String]) throws -> String {
        var map: [String: [String]] = [:]
        for raw in filters {
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw CLIError.io("invalid filter \"\(raw)\"")
            }
            map[String(parts[0]), default: []].append(String(parts[1]))
        }
        let data = try JSONSerialization.data(withJSONObject: map)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// `base` plus optional `filters=` and extra query items.
    static func filteredPath(_ base: String, filters: [String] = [], extra: [String] = []) throws -> String {
        var items = extra
        if !filters.isEmpty {
            items.append("filters=\(query(try filtersJSON(filters)))")
        }
        return items.isEmpty ? base : "\(base)?\(items.joined(separator: "&"))"
    }

    /// Docker `--label-file`: `KEY=value` lines and `#` comments.
    static func labelFile(_ paths: [String]) throws -> [String: String] {
        var labels: [String: String] = [:]
        for path in paths {
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw CLIError.io("can't read label file \(path): \(error.localizedDescription)")
            }
            for (key, value) in EngineLabelFile.parse(text) {
                labels[key] = value
            }
        }
        return labels
    }

    /// Docker `--env-file`: `KEY=value` lines, `#` comments, and `KEY` copied from the host environment.
    static func envFile(_ paths: [String]) throws -> [String] {
        var lines: [String] = []
        for path in paths {
            let text: String
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw CLIError.io("can't read env file \(path): \(error.localizedDescription)")
            }
            for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.contains("=") {
                    lines.append(line)
                    continue
                }
                if let value = ProcessInfo.processInfo.environment[line] {
                    lines.append("\(line)=\(value)")
                }
            }
        }
        return lines
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

    /// `pull -a` / `push -a` take a repository name, not `name:tag` or a digest.
    static func requireNameOnly(_ image: String) throws {
        let lastComponent = image.split(separator: "/").last ?? Substring(image)
        guard !image.contains("@"), !lastComponent.contains(":") else {
            throw ValidationError("tag can't be used with --all-tags/-a")
        }
    }

    static func warnIgnoredPlatform(_ platform: String?, command: String) {
        guard let platform, !platform.isEmpty else { return }
        fputs("WARNING: --platform is ignored; \(command) keeps the host platform\n", stderr)
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
        fputs("Are you sure you want to continue? [y/N] ", stdout)
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    static func secret(_ prompt: String) -> String {
        fputs(prompt, stdout)
        fflush(stdout)
        let tty = isatty(STDIN_FILENO) != 0
        var original = termios()
        if tty {
            tcgetattr(STDIN_FILENO, &original)
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
        }
        defer {
            if tty {
                tcsetattr(STDIN_FILENO, TCSANOW, &original)
                fputs("\n", stdout)
            }
        }
        return readLine() ?? ""
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
