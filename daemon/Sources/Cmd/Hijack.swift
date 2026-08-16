import ContainerEngine
import Darwin
import Foundation

enum TerminalIO {
    static func makeRaw() -> () -> Void {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return {} }
        var raw = original
        cfmakeraw(&raw)
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        return {
            var restore = original
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restore)
        }
    }

    static func windowSize() -> (height: Int, width: Int)? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else {
            return nil
        }
        return (Int(size.ws_row), Int(size.ws_col))
    }

    static func watchResize(_ handler: @escaping (Int, Int) -> Void) -> DispatchSourceSignal {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: DispatchQueue.global())
        source.setEventHandler {
            if let size = windowSize() {
                handler(size.height, size.width)
            }
        }
        source.setCancelHandler {
            signal(SIGWINCH, SIG_DFL)
        }
        source.resume()
        return source
    }
}

enum HijackIO {
    static func copyStdin(to fd: Int32, mux: Bool, detachKeys: [UInt8]? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            var scanner = DetachScanner(keys: detachKeys ?? [])
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { raw in
                    Darwin.read(STDIN_FILENO, raw.baseAddress, raw.count)
                }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 {
                    let rest = scanner.flush()
                    if !rest.isEmpty, !writePayload(Data(rest), to: fd, mux: mux) { return }
                    break
                }
                let bytes = Array(buf.prefix(n))
                let (out, detach) = scanner.ingest(bytes)
                if !out.isEmpty, !writePayload(Data(out), to: fd, mux: mux) { return }
                if detach {
                    _ = Darwin.shutdown(fd, SHUT_RDWR)
                    return
                }
            }
            if mux {
                _ = writeFD(fd, DockerStdio.stdinFrame(Data()))
            }
        }
    }

    @discardableResult
    private static func writePayload(_ data: Data, to fd: Int32, mux: Bool) -> Bool {
        writeFD(fd, mux ? DockerStdio.stdinFrame(data) : data)
    }

    static func writeOutput(_ data: Data, tty: Bool, pending: inout Data) {
        if tty {
            try? FileHandle.standardOutput.write(contentsOf: data)
            return
        }
        pending.append(data)
        let pulled = DockerStdio.pullFrames(&pending)
        for frame in pulled.frames where frame.stream == 1 || frame.stream == 2 {
            let handle = frame.stream == 2 ? FileHandle.standardError : FileHandle.standardOutput
            try? handle.write(contentsOf: frame.payload)
        }
    }

    @discardableResult
    static func writeFD(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var written = 0
            let total = raw.count
            guard let base = raw.baseAddress else { return true }
            while written < total {
                let n = Darwin.write(fd, base + written, total - written)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }
}

enum DetachKeys {
    static let `default`: [UInt8] = [0x10, 0x11]

    static func parse(_ spec: String) throws -> [UInt8] {
        let parts = spec.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw CLIError.http("invalid detach keys: \(spec)")
        }
        return try parts.map { token in
            if token.hasPrefix("ctrl-") {
                let letter = token.dropFirst(5)
                guard letter.count == 1, let scalar = letter.utf8.first, (97...122).contains(scalar) else {
                    throw CLIError.http("invalid detach keys: \(spec)")
                }
                return scalar - 96
            }
            guard token.utf8.count == 1, let scalar = token.utf8.first else {
                throw CLIError.http("invalid detach keys: \(spec)")
            }
            return scalar
        }
    }
}

private struct DetachScanner {
    let keys: [UInt8]
    private var pending: [UInt8] = []

    init(keys: [UInt8]) {
        self.keys = keys
    }

    mutating func ingest(_ bytes: [UInt8]) -> (emitted: [UInt8], detach: Bool) {
        guard !keys.isEmpty else { return (bytes, false) }
        var emitted: [UInt8] = []
        for byte in bytes {
            pending.append(byte)
            if pending.elementsEqual(keys) {
                return (emitted, true)
            }
            while !pending.isEmpty && !keys.starts(with: pending) {
                emitted.append(pending.removeFirst())
            }
        }
        return (emitted, false)
    }

    mutating func flush() -> [UInt8] {
        let rest = pending
        pending = []
        return rest
    }
}
