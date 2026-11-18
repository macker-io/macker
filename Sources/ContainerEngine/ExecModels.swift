import Foundation

public struct EngineExecCreateSpec: Sendable {
    public var cmd: [String]
    public var env: [String]
    public var user: String
    public var workingDir: String
    public var tty: Bool
    public var privileged: Bool
    public var attachStdin: Bool
    public var attachStdout: Bool
    public var attachStderr: Bool
    public var detachKeys: String

    public init(
        cmd: [String],
        env: [String] = [],
        user: String = "",
        workingDir: String = "",
        tty: Bool = false,
        privileged: Bool = false,
        attachStdin: Bool = false,
        attachStdout: Bool = true,
        attachStderr: Bool = true,
        detachKeys: String = ""
    ) {
        self.cmd = cmd
        self.env = env
        self.user = user
        self.workingDir = workingDir
        self.tty = tty
        self.privileged = privileged
        self.attachStdin = attachStdin
        self.attachStdout = attachStdout
        self.attachStderr = attachStderr
        self.detachKeys = detachKeys
    }
}

public struct EngineExec: Sendable {
    public var id: String
    public var containerID: String
    public var cmd: [String]
    public var env: [String]
    public var user: String
    public var workingDir: String
    public var tty: Bool
    public var privileged: Bool
    public var attachStdin: Bool
    public var attachStdout: Bool
    public var attachStderr: Bool
    public var detachKeys: String
    public var started: Bool
    public var running: Bool
    public var exitCode: Int?
    public var pid: Int
    public var height: Int
    public var width: Int

    public init(
        id: String,
        container: EngineContainer,
        spec: EngineExecCreateSpec
    ) {
        self.id = id
        self.containerID = container.id
        self.cmd = spec.cmd
        self.env = spec.env
        self.user = spec.user.isEmpty ? container.user : spec.user
        self.workingDir = spec.workingDir.isEmpty ? container.workingDir : spec.workingDir
        self.tty = spec.tty
        self.privileged = spec.privileged
        self.attachStdin = spec.attachStdin
        self.attachStdout = spec.attachStdout
        self.attachStderr = spec.attachStderr
        self.detachKeys = spec.detachKeys
        self.started = false
        self.running = false
        self.exitCode = nil
        self.pid = 0
        self.height = 0
        self.width = 0
    }
}

/// One stdout or stderr chunk from attach / exec. Adapter multiplexes when `tty` is false.
public struct EngineIOChunk: Sendable {
    public let data: Data
    public let stdout: Bool
    /// When the bytes were logged. Set for log entries (`logs`, attach `logs=1` replay).
    public let time: Date?

    public init(data: Data, stdout: Bool, time: Date? = nil) {
        self.data = data
        self.stdout = stdout
        self.time = time
    }
}

/// Bidirectional I/O session for attach / exec start.
public struct EngineIOSession: Sendable {
    public let tty: Bool
    public let stdin: Bool
    public let chunks: AsyncStream<EngineIOChunk>
    public let writeStdin: @Sendable (Data) async -> Void
    /// The client finished sending stdin (half-close). Closes the process stdin when the
    /// session owns it (exec, or a `StdinOnce` container); otherwise only detaches stdin.
    public let closeStdin: @Sendable () async -> Void
    /// The client went away.
    public let close: @Sendable () async -> Void
}

/// Docker attach/exec stdio: raw when TTY, otherwise 8-byte multiplexed frames.
public enum DockerStdio {
    public static func frame(_ data: Data, stdout: Bool) -> Data {
        guard !data.isEmpty else { return Data() }
        return muxFrame(data, stream: stdout ? 1 : 2)
    }

    /// Pull complete multiplexed frames. Stream 0 is stdin; 1 stdout; 2 stderr.
    public static func pullFrames(_ buffer: inout Data) -> (frames: [(stream: UInt8, payload: Data)], closed: Bool) {
        var frames: [(stream: UInt8, payload: Data)] = []
        var closed = false
        while buffer.count >= 8 {
            let header = [UInt8](buffer.prefix(8))
            let stream = header[0]
            let size =
                (Int(header[4]) << 24)
                | (Int(header[5]) << 16)
                | (Int(header[6]) << 8)
                | Int(header[7])
            guard header[1] == 0, header[2] == 0, header[3] == 0, size >= 0, buffer.count >= 8 + size else {
                break
            }
            let payload = Data(buffer[8..<(8 + size)])
            buffer.removeSubrange(..<(8 + size))
            if stream == 0, size == 0 {
                closed = true
                continue
            }
            frames.append((stream, payload))
        }
        return (frames, closed)
    }

    private static func muxFrame(_ data: Data, stream: UInt8) -> Data {
        var header = [UInt8](repeating: 0, count: 8)
        header[0] = stream
        let size = UInt32(data.count)
        header[4] = UInt8((size >> 24) & 0xff)
        header[5] = UInt8((size >> 16) & 0xff)
        header[6] = UInt8((size >> 8) & 0xff)
        header[7] = UInt8(size & 0xff)
        return Data(header) + data
    }
}
