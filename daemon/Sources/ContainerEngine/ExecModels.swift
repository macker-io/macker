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
}

/// Bidirectional I/O session for attach / exec start (plain text; adapter multiplexes).
public struct EngineIOSession: Sendable {
    public let tty: Bool
    public let chunks: AsyncStream<String>
    public let writeStdin: @Sendable (Data) async -> Void
    public let close: @Sendable () async -> Void
}
