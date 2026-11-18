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
    public let SizeRw: Int64
    public let SizeRootFs: Int64

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
        public let IPAMConfig: IPAMConfig?
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
        public let GwPriority: Int

        public struct IPAMConfig: Encodable, Sendable {
            public let IPv4Address: String
            public let IPv6Address: String?
        }

        public init(_ endpoint: EngineEndpoint) {
            if endpoint.ipv4Address.isEmpty, endpoint.ipv6Address.isEmpty {
                self.IPAMConfig = nil
            } else {
                self.IPAMConfig = .init(
                    IPv4Address: endpoint.ipv4Address,
                    IPv6Address: endpoint.ipv6Address.isEmpty ? nil : endpoint.ipv6Address
                )
            }
            self.Links = nil
            self.Aliases = endpoint.aliases
            self.NetworkID = endpoint.networkID
            self.EndpointID = String(endpoint.networkID.prefix(12)) + String(endpoint.ipv4Address.filter { $0 != "." }.suffix(12))
            self.Gateway = endpoint.gateway
            self.IPAddress = endpoint.ipv4Address
            self.IPPrefixLen = endpoint.ipv4Prefix
            self.IPv6Gateway = endpoint.ipv6Gateway
            self.GlobalIPv6Address = endpoint.ipv6Address
            self.GlobalIPv6PrefixLen = endpoint.ipv6Prefix
            self.MacAddress = endpoint.macAddress
            self.DriverOpts = endpoint.driverOpts.isEmpty ? nil : endpoint.driverOpts
            self.GwPriority = endpoint.gwPriority
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
        self.Mounts = engine.mounts.map(Mount.init)
        self.SizeRw = engine.sizeRw
        self.SizeRootFs = engine.sizeRootFs
    }
}

public struct DockerCreateContainerRequest: Decodable, Sendable {
    public let Hostname: String?
    public let Domainname: String?
    public let User: String?
    public let Env: [String]?
    public let Cmd: FlexibleStringList?
    public let Entrypoint: FlexibleStringList?
    public let Image: String
    public let Labels: [String: String]?
    public let WorkingDir: String?
    public let Tty: Bool?
    public let OpenStdin: Bool?
    public let StdinOnce: Bool?
    public let Volumes: [String: EmptyObject]?
    public let ExposedPorts: [String: EmptyObject]?
    public let Healthcheck: Healthcheck?
    /// Top-level `ContainerConfig` fields (not `HostConfig`).
    public let StopSignal: String?
    public let StopTimeout: Int?
    public let NetworkDisabled: Bool?
    public let HostConfig: HostConfig?
    public let NetworkingConfig: NetworkingConfig?

    /// Any JSON object; only presence/count matters.
    public struct EmptyObject: Decodable, Sendable {}

    public struct Healthcheck: Decodable, Sendable {
        public let Test: [String]?
        public let Interval: Int64?
        public let Timeout: Int64?
        public let StartPeriod: Int64?
        public let StartInterval: Int64?
        public let Retries: Int?
    }

    public struct HostConfig: Decodable, Sendable {
        public let Memory: Int64?
        public let NanoCpus: Int64?
        public let AutoRemove: Bool?
        public let NetworkMode: String?
        public let Binds: [String]?
        public let Mounts: [DockerMountConfig]?
        public let PortBindings: [String: [DockerPortBinding]]?
        public let PublishAllPorts: Bool?
        public let Privileged: Bool?
        public let ReadonlyRootfs: Bool?
        public let Dns: [String]?
        public let DnsSearch: [String]?
        public let DnsOptions: [String]?
        public let ExtraHosts: [String]?
        public let RestartPolicy: RestartPolicy?
        public let StopSignal: String?
        public let StopTimeout: Int?
        public let GroupAdd: [String]?
        public let VolumesFrom: [String]?
        public let Tmpfs: [String: String]?
        public let VolumeDriver: String?
        public let Init: Bool?

        public let Sysctls: [String: String]?
        public let CapAdd: [String]?
        public let CapDrop: [String]?
        public let SecurityOpt: [String]?
        public let Ulimits: [Ulimit]?

        // Decoded only so non-default values can be rejected (see `DockerCreateValidator`).
        public let PidMode: String?
        public let IpcMode: String?
        public let UTSMode: String?
        public let UsernsMode: String?
        public let CgroupnsMode: String?
        public let Cgroup: String?
        public let CgroupParent: String?
        public let Devices: [EmptyObject]?
        public let DeviceRequests: [EmptyObject]?
        public let DeviceCgroupRules: [String]?
        public let Links: [String]?
        public let OomScoreAdj: Int?
        public let OomKillDisable: Bool?
        public let PidsLimit: Int64?
        public let ShmSize: Int64?
        public let CpuShares: Int64?
        public let CpuPeriod: Int64?
        public let CpuQuota: Int64?
        public let CpuRealtimePeriod: Int64?
        public let CpuRealtimeRuntime: Int64?
        public let CpusetCpus: String?
        public let CpusetMems: String?
        public let CpuCount: Int64?
        public let CpuPercent: Int64?
        public let IOMaximumIOps: Int64?
        public let IOMaximumBandwidth: Int64?
        public let BlkioWeight: Int64?
        public let BlkioWeightDevice: [EmptyObject]?
        public let BlkioDeviceReadBps: [EmptyObject]?
        public let BlkioDeviceWriteBps: [EmptyObject]?
        public let BlkioDeviceReadIOps: [EmptyObject]?
        public let BlkioDeviceWriteIOps: [EmptyObject]?
        public let MemoryReservation: Int64?
        public let MemorySwap: Int64?
        public let MemorySwappiness: Int64?
        public let LogConfig: LogConfig?
        public let Runtime: String?
        public let Isolation: String?
        public let MaskedPaths: [String]?
        public let ReadonlyPaths: [String]?
        public let StorageOpt: [String: String]?
        public let Annotations: [String: String]?

        public struct RestartPolicy: Decodable, Sendable {
            public let Name: String?
            public let MaximumRetryCount: Int?
        }

        public struct LogConfig: Decodable, Sendable {
            public let `Type`: String?
            public let Config: [String: String]?
        }

        public struct Ulimit: Decodable, Sendable {
            public let Name: String
            public let Soft: Int64?
            public let Hard: Int64?
        }
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
    public let VolumeOptions: VolumeOptions?

    public struct VolumeOptions: Decodable, Sendable {
        public let DriverConfig: DriverConfig?
    }

    public struct DriverConfig: Decodable, Sendable {
        public let Name: String?
    }
}

public struct DockerPortBinding: Codable, Sendable {
    public let HostIp: String?
    public let HostPort: String?
}

public struct DockerEndpointConfig: Decodable, Sendable {
    public let Aliases: [String]?
    public let Links: [String]?
    public let MacAddress: String?
    public let IPAMConfig: IPAMConfig?
    public let DriverOpts: [String: String]?
    public let GwPriority: Int?

    public struct IPAMConfig: Decodable, Sendable {
        public let IPv4Address: String?
        public let IPv6Address: String?
        public let LinkLocalIPs: [String]?
    }
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
    public let RestartCount: Int
    public let Driver: String
    public let Platform: String
    public let HostConfig: HostConfig
    public let Config: Config
    public let NetworkSettings: NetworkSettings
    public let Mounts: [DockerContainerSummary.Mount]
    public let SizeRw: Int64
    public let SizeRootFs: Int64

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
        public let Health: Health?

        public struct Health: Encodable, Sendable {
            public let Status: String
            public let FailingStreak: Int
            public let Log: [Log]

            public struct Log: Encodable, Sendable {
                public let Start: String
                public let End: String
                public let ExitCode: Int
                public let Output: String
            }
        }
    }

    public struct HostConfig: Encodable, Sendable {
        public let NetworkMode: String
        public let Memory: Int64
        public let NanoCpus: Int64
        public let AutoRemove: Bool
        public let Privileged: Bool
        /// `null` when unset, like Docker.
        public let CapAdd: [String]?
        public let CapDrop: [String]?
        public let ReadonlyRootfs: Bool
        public let PublishAllPorts: Bool
        public let Dns: [String]
        public let DnsSearch: [String]
        public let DnsOptions: [String]
        public let ExtraHosts: [String]
        public let GroupAdd: [String]
        public let RestartPolicy: RestartPolicy
        public let PortBindings: [String: [DockerPortBinding]]
        /// Omitted unless `--init` was requested, like Docker's `*bool`.
        public let Init: Bool?
        public let Sysctls: [String: String]?
        public let SecurityOpt: [String]?
        public let Ulimits: [Ulimit]?
        public let LogConfig: LogConfig

        public struct Ulimit: Encodable, Sendable {
            public let Name: String
            public let Soft: Int64
            public let Hard: Int64
        }

        public struct RestartPolicy: Encodable, Sendable {
            public let Name: String
            public let MaximumRetryCount: Int
        }

        public struct LogConfig: Encodable, Sendable {
            public let `Type`: String
            public let Config: [String: String]
        }
    }

    public struct Config: Encodable, Sendable {
        public let Hostname: String
        public let Domainname: String
        public let User: String
        public let Env: [String]
        public let Cmd: [String]?
        public let Entrypoint: [String]?
        public let Image: String
        public let WorkingDir: String
        public let Labels: [String: String]
        public let Tty: Bool
        public let OpenStdin: Bool
        public let StdinOnce: Bool
        public let ExposedPorts: [String: EmptyObject]
        public let Healthcheck: Healthcheck?
        /// Omitted when unset, like Docker.
        public let StopSignal: String?
        public let StopTimeout: Int?

        public struct EmptyObject: Encodable, Sendable {}

        public struct Healthcheck: Encodable, Sendable {
            public let Test: [String]
            public let Interval: Int64
            public let Timeout: Int64
            public let StartPeriod: Int64
            public let StartInterval: Int64
            public let Retries: Int
        }
    }

    public struct NetworkSettings: Encodable, Sendable {
        public let Bridge: String
        public let SandboxID: String
        public let Ports: [String: [DockerPortBinding]?]
        public let Gateway: String
        public let IPAddress: String
        public let IPPrefixLen: Int
        public let IPv6Gateway: String
        public let GlobalIPv6Address: String
        public let GlobalIPv6PrefixLen: Int
        public let MacAddress: String
        public let Networks: [String: DockerContainerSummary.EndpointSettings]
    }

    public init(_ container: EngineContainer, sizeRw: Int64 = -1, sizeRootFs: Int64 = -1) {
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
            FinishedAt: container.finishedAt.map { iso.string(from: $0) } ?? "0001-01-01T00:00:00Z",
            Health: container.health.map { health in
                .init(
                    Status: health.status,
                    FailingStreak: health.failingStreak,
                    Log: health.log.map {
                        .init(
                            Start: iso.string(from: $0.start),
                            End: iso.string(from: $0.end),
                            ExitCode: $0.exitCode,
                            Output: $0.output
                        )
                    }
                )
            }
        )
        self.Image = container.imageID
        self.Name = "/\(container.name)"
        self.RestartCount = container.run.restartCount
        self.Driver = "containerization"
        self.Platform = "linux"
        self.HostConfig = .init(
            NetworkMode: container.networkMode,
            Memory: container.memory,
            NanoCpus: container.nanoCpus,
            AutoRemove: container.autoRemove,
            Privileged: container.run.privileged,
            CapAdd: container.run.capAdd.isEmpty ? nil : container.run.capAdd,
            CapDrop: container.run.capDrop.isEmpty ? nil : container.run.capDrop,
            ReadonlyRootfs: container.run.readonlyRootfs,
            PublishAllPorts: container.run.publishAllPorts,
            Dns: container.run.dns,
            DnsSearch: container.run.dnsSearch,
            DnsOptions: container.run.dnsOptions,
            ExtraHosts: container.run.extraHosts,
            GroupAdd: container.run.groupAdd,
            RestartPolicy: .init(
                Name: container.run.restartPolicy.name,
                MaximumRetryCount: container.run.restartPolicy.maximumRetryCount
            ),
            PortBindings: Self.portBindings(container.portBindings),
            Init: container.run.useInit ? true : nil,
            Sysctls: container.run.sysctls.isEmpty ? nil : container.run.sysctls,
            SecurityOpt: container.run.securityOpt.isEmpty ? nil : container.run.securityOpt,
            Ulimits: container.run.ulimits.isEmpty ? nil : container.run.ulimits.map {
                .init(Name: $0.name, Soft: Int64(bitPattern: $0.soft), Hard: Int64(bitPattern: $0.hard))
            },
            LogConfig: .init(Type: "json-file", Config: [:])
        )
        self.Config = .init(
            Hostname: container.hostname,
            Domainname: container.run.domainname,
            User: container.user,
            Env: container.env,
            // Records from before entrypoint/cmd were kept separately only have `command`.
            Cmd: container.run.cmd ?? container.command,
            Entrypoint: container.run.entrypoint.flatMap { $0.isEmpty ? nil : $0 },
            Image: container.image,
            WorkingDir: container.workingDir,
            Labels: container.labels,
            Tty: container.tty,
            OpenStdin: container.openStdin,
            StdinOnce: container.stdinOnce,
            ExposedPorts: Dictionary(uniqueKeysWithValues: container.exposedPorts.map { ($0.dockerKey, .init()) }),
            Healthcheck: container.run.healthcheck.map {
                .init(
                    Test: $0.test,
                    Interval: $0.intervalNanos,
                    Timeout: $0.timeoutNanos,
                    StartPeriod: $0.startPeriodNanos,
                    StartInterval: $0.startIntervalNanos,
                    Retries: $0.retries
                )
            },
            StopSignal: container.run.stopSignal.isEmpty ? nil : container.run.stopSignal,
            StopTimeout: container.run.stopTimeout > 0 ? container.run.stopTimeout : nil
        )
        let primary = container.endpoints.first
        self.NetworkSettings = .init(
            Bridge: container.networkMode == "bridge" ? "bridge" : "",
            SandboxID: String(container.id.prefix(12)),
            Ports: Self.publishedPorts(container.portBindings),
            Gateway: primary?.gateway ?? "",
            IPAddress: primary?.ipv4Address ?? "",
            IPPrefixLen: primary?.ipv4Prefix ?? 0,
            IPv6Gateway: primary?.ipv6Gateway ?? "",
            GlobalIPv6Address: primary?.ipv6Address ?? "",
            GlobalIPv6PrefixLen: primary?.ipv6Prefix ?? 0,
            MacAddress: primary?.macAddress ?? "",
            Networks: Dictionary(uniqueKeysWithValues: container.endpoints.map {
                ($0.networkName, DockerContainerSummary.EndpointSettings($0))
            })
        )
        self.Mounts = container.mounts.map(DockerContainerSummary.Mount.init)
        self.SizeRw = sizeRw
        self.SizeRootFs = sizeRootFs
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

/// `POST /containers/{id}/wait`.
public struct DockerWaitResponse: Encodable, Sendable {
    public let StatusCode: Int
    public let Error: WaitError?

    public struct WaitError: Encodable, Sendable {
        public let Message: String
    }

    public init(StatusCode: Int, Error: WaitError? = nil) {
        self.StatusCode = StatusCode
        self.Error = Error
    }
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
    public var Memory: Int64?
    public var NanoCpus: Int64?
    public var RestartPolicy: RestartPolicy?
    public var CpuShares: Int64?
    public var CpuPeriod: Int64?
    public var CpuQuota: Int64?
    public var CpuRealtimePeriod: Int64?
    public var CpuRealtimeRuntime: Int64?
    public var CpusetCpus: String?
    public var CpusetMems: String?
    public var MemoryReservation: Int64?
    public var MemorySwap: Int64?
    public var BlkioWeight: Int64?
    public var PidsLimit: Int64?
    public var KernelMemory: Int64?
    public var CpuCount: Int64?
    public var CpuPercent: Int64?
    public var IOMaximumIOps: Int64?
    public var IOMaximumBandwidth: Int64?

    public struct RestartPolicy: Decodable, Sendable {
        public var Name: String?
        public var MaximumRetryCount: Int?
    }

    public init() {}

    /// `0` means "leave unchanged", matching Docker's container update.
    public var appliedMemory: Int64? {
        guard let Memory, Memory != 0 else { return nil }
        return Memory
    }

    public var appliedNanoCpus: Int64? {
        guard let NanoCpus, NanoCpus != 0 else { return nil }
        return NanoCpus
    }

    /// Non-zero resource fields the Docker update API accepts and this runtime does not apply.
    public func ignoredResourceWarnings() -> [String] {
        var warnings: [String] = []
        func ignore(_ label: String, _ value: Int64?) {
            if let value, value != 0 {
                warnings.append("\(label) is not supported on this runtime and was ignored")
            }
        }
        func ignoreText(_ label: String, _ value: String?) {
            if let value, !value.isEmpty {
                warnings.append("\(label) is not supported on this runtime and was ignored")
            }
        }
        ignore("CpuShares", CpuShares)
        ignore("CpuPeriod", CpuPeriod)
        ignore("CpuQuota", CpuQuota)
        ignore("CpuRealtimePeriod", CpuRealtimePeriod)
        ignore("CpuRealtimeRuntime", CpuRealtimeRuntime)
        ignoreText("CpusetCpus", CpusetCpus)
        ignoreText("CpusetMems", CpusetMems)
        ignore("MemoryReservation", MemoryReservation)
        ignore("MemorySwap", MemorySwap)
        ignore("BlkioWeight", BlkioWeight)
        if PidsLimit != nil {
            warnings.append("PidsLimit is not supported on this runtime and was ignored")
        }
        ignore("KernelMemory", KernelMemory)
        ignore("CpuCount", CpuCount)
        ignore("CpuPercent", CpuPercent)
        ignore("IOMaximumIOps", IOMaximumIOps)
        ignore("IOMaximumBandwidth", IOMaximumBandwidth)
        return warnings
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

/// `GET /containers/{id}/changes`.
public struct DockerFilesystemChange: Encodable, Sendable {
    public let Path: String
    public let Kind: Int

    public init(_ change: EngineFSChange) {
        self.Path = change.path
        self.Kind = change.kind.rawValue
    }
}
