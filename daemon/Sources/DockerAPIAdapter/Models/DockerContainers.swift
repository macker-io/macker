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

    public struct Port: Encodable, Sendable {
        public let IP: String
        public let PrivatePort: Int
        public let PublicPort: Int
        public let `Type`: String

        public init(_ binding: EnginePortBinding) {
            self.IP = binding.hostIP.isEmpty ? "0.0.0.0" : binding.hostIP
            self.PrivatePort = binding.containerPort
            self.PublicPort = binding.hostPort
            self.`Type` = binding.protocolName
        }
    }

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

    public struct EndpointSettings: Encodable, Sendable {
        public let IPAMConfig: EmptyObject?
        public let Links: [String]?
        public let Aliases: [String]
        public let NetworkID: String
        public let EndpointID: String
        public let Gateway: String
        public let IPAddress: String
        public let IPPrefixLen: Int
        public let IPv6Gateway: String
        public let GlobalIPv6Address: String
        public let GlobalIPv6PrefixLen: Int
        public let MacAddress: String
        public let DriverOpts: [String: String]?

        public struct EmptyObject: Encodable, Sendable {}

        public init(_ endpoint: EngineEndpoint) {
            self.IPAMConfig = nil
            self.Links = nil
            self.Aliases = endpoint.aliases
            self.NetworkID = endpoint.networkID
            self.EndpointID = String(endpoint.networkID.prefix(12)) + String(endpoint.ipv4Address.filter { $0 != "." }.suffix(12))
            self.Gateway = endpoint.gateway
            self.IPAddress = endpoint.ipv4Address
            self.IPPrefixLen = endpoint.ipv4Prefix
            self.IPv6Gateway = ""
            self.GlobalIPv6Address = ""
            self.GlobalIPv6PrefixLen = 0
            self.MacAddress = endpoint.macAddress
            self.DriverOpts = nil
        }
    }

    public init(_ engine: EngineContainerSummary) {
        self.Id = engine.id
        self.Names = engine.names
        self.Image = engine.image
        self.ImageID = engine.imageID
        self.Command = engine.command
        self.Created = Int64(engine.created.timeIntervalSince1970)
        self.Ports = engine.ports.map(Port.init)
        self.Labels = engine.labels
        self.State = engine.state
        self.Status = engine.status
        self.HostConfig = .init(NetworkMode: engine.networkMode)
        self.NetworkSettings = .init(
            Networks: Dictionary(uniqueKeysWithValues: engine.endpoints.map { ($0.networkName, EndpointSettings($0)) })
        )
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
    public let ExposedPorts: [String: EmptyObject]?
    public let HostConfig: HostConfig?
    public let NetworkingConfig: NetworkingConfig?

    public struct EmptyObject: Decodable, Sendable {}

    public struct HostConfig: Decodable, Sendable {
        public let Memory: Int64?
        public let NanoCpus: Int64?
        public let AutoRemove: Bool?
        public let NetworkMode: String?
        public let Binds: [String]?
        public let Mounts: [DockerMountConfig]?
        public let PortBindings: [String: [DockerPortBinding]]?
    }

    public struct NetworkingConfig: Decodable, Sendable {
        public let EndpointsConfig: [String: DockerEndpointConfig]?
    }
}

public struct DockerMountConfig: Decodable, Sendable {
    public let `Type`: String?
    public let Source: String?
    public let Target: String?
    public let ReadOnly: Bool?
}

public struct DockerPortBinding: Codable, Sendable {
    public let HostIp: String?
    public let HostPort: String?
}

public struct DockerEndpointConfig: Decodable, Sendable {
    public let Aliases: [String]?
    public let IPAMConfig: EmptyObject?

    public struct EmptyObject: Decodable, Sendable {}
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
        public let PortBindings: [String: [DockerPortBinding]]
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
        public let ExposedPorts: [String: EmptyObject]

        public struct EmptyObject: Encodable, Sendable {}
    }

    public struct NetworkSettings: Encodable, Sendable {
        public let Bridge: String
        public let SandboxID: String
        public let Ports: [String: [DockerPortBinding]?]
        public let Gateway: String
        public let IPAddress: String
        public let IPPrefixLen: Int
        public let MacAddress: String
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
            AutoRemove: container.autoRemove,
            PortBindings: Self.portBindings(container.portBindings)
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
            OpenStdin: container.openStdin,
            ExposedPorts: Dictionary(uniqueKeysWithValues: container.exposedPorts.map { ($0.dockerKey, .init()) })
        )
        let primary = container.endpoints.first
        self.NetworkSettings = .init(
            Bridge: container.networkMode == "bridge" ? "bridge" : "",
            SandboxID: String(container.id.prefix(12)),
            Ports: Self.publishedPorts(container.portBindings),
            Gateway: primary?.gateway ?? "",
            IPAddress: primary?.ipv4Address ?? "",
            IPPrefixLen: primary?.ipv4Prefix ?? 0,
            MacAddress: primary?.macAddress ?? "",
            Networks: Dictionary(uniqueKeysWithValues: container.endpoints.map {
                ($0.networkName, DockerContainerSummary.EndpointSettings($0))
            })
        )
        self.Mounts = container.mounts.map(DockerContainerSummary.Mount.init)
    }

    private static func portBindings(_ bindings: [EnginePortBinding]) -> [String: [DockerPortBinding]] {
        var mapped: [String: [DockerPortBinding]] = [:]
        for binding in bindings {
            mapped[binding.dockerKey, default: []].append(
                DockerPortBinding(
                    HostIp: binding.hostIP,
                    HostPort: binding.hostPort == 0 ? "" : String(binding.hostPort)
                )
            )
        }
        return mapped
    }

    private static func publishedPorts(_ bindings: [EnginePortBinding]) -> [String: [DockerPortBinding]?] {
        var mapped: [String: [DockerPortBinding]] = [:]
        for binding in bindings {
            mapped[binding.dockerKey, default: []].append(
                DockerPortBinding(
                    HostIp: binding.hostIP.isEmpty ? "0.0.0.0" : binding.hostIP,
                    HostPort: String(binding.hostPort)
                )
            )
        }
        return mapped.mapValues { .some($0) }
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
    public let preread: String
    public let id: String
    public let name: String
    public let cpu_stats: CPUStats
    public let precpu_stats: CPUStats
    public let memory_stats: MemoryStats
    public let networks: [String: NetworkStats]
    public let pids_stats: PidsStats

    public struct CPUStats: Encodable, Sendable {
        public let cpu_usage: CPUUsage
        public let system_cpu_usage: UInt64
        public let online_cpus: Int
    }

    public struct CPUUsage: Encodable, Sendable {
        public let total_usage: UInt64
    }

    public struct MemoryStats: Encodable, Sendable {
        public let usage: UInt64
        public let limit: UInt64
    }

    public struct NetworkStats: Encodable, Sendable {
        public let rx_bytes: UInt64
        public let tx_bytes: UInt64
        public let rx_packets: UInt64
        public let tx_packets: UInt64
        public let rx_errors: UInt64
        public let tx_errors: UInt64
        public let rx_dropped: UInt64
        public let tx_dropped: UInt64
    }

    public struct PidsStats: Encodable, Sendable {
        public let current: Int
    }

    public init(_ stats: EngineContainerStats) {
        self.read = ISO8601.string(from: stats.read)
        self.preread = ISO8601.string(from: stats.read.addingTimeInterval(-1))
        self.id = stats.id
        self.name = stats.name
        self.cpu_stats = .init(
            cpu_usage: .init(total_usage: stats.cpuTotal),
            system_cpu_usage: stats.cpuSystem,
            online_cpus: stats.onlineCPUs
        )
        self.precpu_stats = .init(
            cpu_usage: .init(total_usage: stats.preCPUTotal),
            system_cpu_usage: stats.preCPUSystem,
            online_cpus: stats.onlineCPUs
        )
        self.memory_stats = .init(usage: stats.memoryUsage, limit: stats.memoryLimit)
        self.networks = stats.networks.mapValues {
            .init(
                rx_bytes: $0.rxBytes,
                tx_bytes: $0.txBytes,
                rx_packets: 0,
                tx_packets: 0,
                rx_errors: 0,
                tx_errors: 0,
                rx_dropped: 0,
                tx_dropped: 0
            )
        }
        self.pids_stats = .init(current: stats.pids)
    }
}
