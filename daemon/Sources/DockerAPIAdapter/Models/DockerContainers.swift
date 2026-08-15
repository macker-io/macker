import ContainerEngine
import Foundation

/// `GET /containers/json` — Docker `ContainerSummary`.
public struct DockerContainerSummary: Encodable, Sendable {
    public let Id: String
    public let Names: [String]
    public let Image: String
    public let ImageID: String
    public let Command: String
    public let Created: Int64
    public let Ports: [Port]
    public let Labels: [String: String]
    public let State: String
    public let Status: String
    public let HostConfig: HostConfig
    public let NetworkSettings: NetworkSettings
    public let Mounts: [Mount]

    public struct Port: Encodable, Sendable {}

    public struct Mount: Encodable, Sendable {
        public let `Type`: String
        public let Name: String
        public let Source: String
        public let Destination: String
        public let Driver: String
        public let Mode: String
        public let RW: Bool
        public let Propagation: String

        public init(_ mount: EngineMount) {
            self.`Type` = mount.type
            self.Name = mount.name
            self.Source = mount.source
            self.Destination = mount.destination
            self.Driver = mount.type == "volume" ? "local" : ""
            self.Mode = mount.rw ? "" : "ro"
            self.RW = mount.rw
            self.Propagation = ""
        }
    }

    public struct HostConfig: Encodable, Sendable {
        public let NetworkMode: String
    }

    public struct NetworkSettings: Encodable, Sendable {
        public let Networks: [String: EndpointSettings]
    }

    public struct EndpointSettings: Encodable, Sendable {}

    public init(_ engine: EngineContainerSummary) {
        self.Id = engine.id
        self.Names = engine.names
        self.Image = engine.image
        self.ImageID = engine.imageID
        self.Command = engine.command
        self.Created = Int64(engine.created.timeIntervalSince1970)
        self.Ports = []
        self.Labels = engine.labels
        self.State = engine.state
        self.Status = engine.status
        self.HostConfig = .init(NetworkMode: "default")
        self.NetworkSettings = .init(Networks: [:])
        self.Mounts = []
    }
}

public struct DockerCreateContainerRequest: Decodable, Sendable {
    public let Hostname: String?
    public let User: String?
    public let Env: [String]?
    public let Cmd: FlexibleStringList?
    public let Entrypoint: FlexibleStringList?
    public let Image: String
    public let Labels: [String: String]?
    public let WorkingDir: String?
    public let Tty: Bool?
    public let OpenStdin: Bool?
    public let Volumes: [String: EmptyObject]?
    public let HostConfig: HostConfig?

    public struct EmptyObject: Decodable, Sendable {}

    public struct HostConfig: Decodable, Sendable {
        public let Memory: Int64?
        public let NanoCpus: Int64?
        public let AutoRemove: Bool?
        public let NetworkMode: String?
        public let Binds: [String]?
        public let Mounts: [DockerMountConfig]?
    }
}

public struct DockerMountConfig: Decodable, Sendable {
    public let `Type`: String?
    public let Source: String?
    public let Target: String?
    public let ReadOnly: Bool?
}

/// Docker sends Cmd/Entrypoint as either a string or an array of strings.
public enum FlexibleStringList: Decodable, Sendable {
    case string(String)
    case array([String])

    public var values: [String] {
        switch self {
        case .string(let value):
            return ["/bin/sh", "-c", value]
        case .array(let values):
            return values
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([String].self) {
            self = .array(values)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .array([])
        }
    }
}

public struct DockerCreateContainerResponse: Encodable, Sendable {
    public let Id: String
    public let Warnings: [String]
}

public struct DockerContainerInspect: Encodable, Sendable {
    public let Id: String
    public let Created: String
    public let Path: String
    public let Args: [String]
    public let State: State
    public let Image: String
    public let Name: String
    public let Driver: String
    public let Platform: String
    public let HostConfig: HostConfig
    public let Config: Config
    public let NetworkSettings: NetworkSettings
    public let Mounts: [DockerContainerSummary.Mount]

    public struct State: Encodable, Sendable {
        public let Status: String
        public let Running: Bool
        public let Paused: Bool
        public let Restarting: Bool
        public let OOMKilled: Bool
        public let Dead: Bool
        public let Pid: Int
        public let ExitCode: Int
        public let Error: String
        public let StartedAt: String
        public let FinishedAt: String
    }

    public struct HostConfig: Encodable, Sendable {
        public let NetworkMode: String
        public let Memory: Int64
        public let NanoCpus: Int64
        public let AutoRemove: Bool
    }

    public struct Config: Encodable, Sendable {
        public let Hostname: String
        public let User: String
        public let Env: [String]
        public let Cmd: [String]
        public let Image: String
        public let WorkingDir: String
        public let Labels: [String: String]
        public let Tty: Bool
        public let OpenStdin: Bool
    }

    public struct NetworkSettings: Encodable, Sendable {
        public let Networks: [String: DockerContainerSummary.EndpointSettings]
    }

    public init(_ container: EngineContainer) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.Id = container.id
        self.Created = iso.string(from: container.created)
        self.Path = container.command.first ?? ""
        self.Args = Array(container.command.dropFirst())
        self.State = .init(
            Status: container.state,
            Running: container.state == "running",
            Paused: container.state == "paused",
            Restarting: false,
            OOMKilled: false,
            Dead: container.state == "dead",
            Pid: container.state == "running" ? 1 : 0,
            ExitCode: container.exitCode,
            Error: "",
            StartedAt: container.startedAt.map { iso.string(from: $0) } ?? "0001-01-01T00:00:00Z",
            FinishedAt: container.finishedAt.map { iso.string(from: $0) } ?? "0001-01-01T00:00:00Z"
        )
        self.Image = container.imageID
        self.Name = "/\(container.name)"
        self.Driver = "containerization"
        self.Platform = "linux"
        self.HostConfig = .init(
            NetworkMode: container.networkMode,
            Memory: container.memory,
            NanoCpus: container.nanoCpus,
            AutoRemove: container.autoRemove
        )
        self.Config = .init(
            Hostname: container.hostname,
            User: container.user,
            Env: container.env,
            Cmd: container.command,
            Image: container.image,
            WorkingDir: container.workingDir,
            Labels: container.labels,
            Tty: container.tty,
            OpenStdin: container.openStdin
        )
        self.NetworkSettings = .init(Networks: [:])
        self.Mounts = container.mounts.map(DockerContainerSummary.Mount.init)
    }
}

public struct DockerWaitResponse: Encodable, Sendable {
    public let StatusCode: Int
}

public struct DockerTopResponse: Encodable, Sendable {
    public let Titles: [String]
    public let Processes: [[String]]

    public init(_ top: EngineContainerTop) {
        self.Titles = top.titles
        self.Processes = top.processes
    }
}

public struct DockerContainerPruneResponse: Encodable, Sendable {
    public let ContainersDeleted: [String]
    public let SpaceReclaimed: Int64
}

public struct DockerUpdateContainerRequest: Decodable, Sendable {
    public let Memory: Int64?
    public let NanoCpus: Int64?

    public init(Memory: Int64? = nil, NanoCpus: Int64? = nil) {
        self.Memory = Memory
        self.NanoCpus = NanoCpus
    }
}

public struct DockerUpdateContainerResponse: Encodable, Sendable {
    public let Warnings: [String]
}

public struct DockerContainerStats: Encodable, Sendable {
    public let read: String
    public let cpu_stats: CPUStats
    public let precpu_stats: CPUStats
    public let memory_stats: MemoryStats
    public let networks: [String: NetworkStats]

    public struct CPUStats: Encodable, Sendable {
        public let cpu_usage: CPUUsage
        public let system_cpu_usage: Int
        public let online_cpus: Int
    }

    public struct CPUUsage: Encodable, Sendable {
        public let total_usage: Int
    }

    public struct MemoryStats: Encodable, Sendable {
        public let usage: Int64
        public let limit: Int64
    }

    public struct NetworkStats: Encodable, Sendable {
        public let rx_bytes: Int
        public let tx_bytes: Int
    }

    public init(memoryLimit: Int64) {
        self.read = ISO8601DateFormatter().string(from: Date())
        self.cpu_stats = .init(cpu_usage: .init(total_usage: 0), system_cpu_usage: 0, online_cpus: 1)
        self.precpu_stats = .init(cpu_usage: .init(total_usage: 0), system_cpu_usage: 0, online_cpus: 1)
        self.memory_stats = .init(usage: 0, limit: memoryLimit > 0 ? memoryLimit : 1_073_741_824)
        self.networks = [:]
    }
}
