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
    static func copyStdin(to fd: Int32, mux: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { raw in
                    Darwin.read(STDIN_FILENO, raw.baseAddress, raw.count)
                }
                if n <= 0 { break }
                var payload = Data(buf.prefix(n))
                if mux {
                    payload = DockerStdio.stdinFrame(payload)
                }
                if !writeFD(fd, payload) { break }
            }
            if mux {
                _ = writeFD(fd, DockerStdio.stdinFrame(Data()))
            }
        }
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
