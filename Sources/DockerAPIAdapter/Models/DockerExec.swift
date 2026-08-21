import ContainerEngine
import Foundation

public struct DockerCreateExecRequest: Decodable, Sendable {
    public let AttachStdin: Bool?
    public let AttachStdout: Bool?
    public let AttachStderr: Bool?
    public let DetachKeys: String?
    public let Tty: Bool?
    public let Env: [String]?
    public let Cmd: FlexibleStringList?
    public let Privileged: Bool?
    public let User: String?
    public let WorkingDir: String?
}

public struct DockerCreateExecResponse: Encodable, Sendable {
    public let Id: String
}

public struct DockerExecStartRequest: Decodable, Sendable {
    public let Detach: Bool?
    public let Tty: Bool?

    public init(Detach: Bool? = nil, Tty: Bool? = nil) {
        self.Detach = Detach
        self.Tty = Tty
    }
}

public struct DockerExecInspect: Encodable, Sendable {
    public let CanRemove: Bool
    public let ContainerID: String
    public let DetachKeys: String
    public let ExitCode: Int?
    public let ID: String
    public let OpenStderr: Bool
    public let OpenStdin: Bool
    public let OpenStdout: Bool
    public let Running: Bool
    public let Pid: Int
    public let ProcessConfig: ProcessConfig

    public struct ProcessConfig: Encodable, Sendable {
        public let arguments: [String]
        public let entrypoint: String
        public let privileged: Bool
        public let tty: Bool
        public let user: String
    }

    public init(_ exec: EngineExec) {
        self.CanRemove = !exec.running
        self.ContainerID = exec.containerID
        self.DetachKeys = exec.detachKeys
        self.ExitCode = exec.exitCode
        self.ID = exec.id
        self.OpenStderr = exec.attachStderr
        self.OpenStdin = exec.attachStdin
        self.OpenStdout = exec.attachStdout
        self.Running = exec.running
        self.Pid = exec.pid
        self.ProcessConfig = .init(
            arguments: Array(exec.cmd.dropFirst()),
            entrypoint: exec.cmd.first ?? "",
            privileged: exec.privileged,
            tty: exec.tty,
            user: exec.user
        )
    }
}
