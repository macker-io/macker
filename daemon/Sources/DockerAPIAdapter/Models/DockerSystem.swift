import ContainerEngine
import Foundation

/// `GET /version` — Docker `SystemVersion`.
public struct DockerVersionResponse: Encodable, Sendable {
    public let Platform: PlatformInfo
    public let Components: [ComponentVersion]
    public let Version: String
    public let ApiVersion: String
    public let MinAPIVersion: String
    public let GitCommit: String
    public let GoVersion: String
    public let Os: String
    public let Arch: String
    public let KernelVersion: String
    public let Experimental: Bool
    public let BuildTime: String

    public struct PlatformInfo: Encodable, Sendable {
        public let Name: String
    }

    public struct ComponentVersion: Encodable, Sendable {
        public let Name: String
        public let Version: String
        public let Details: [String: String]?
    }

    public static func current() -> DockerVersionResponse {
        let details: [String: String] = [
            "ApiVersion": DockerAPI.version,
            "MinAPIVersion": DockerAPI.version,
            "Os": "darwin",
            "Arch": "arm64",
            "Experimental": "true",
        ]
        return DockerVersionResponse(
            Platform: .init(Name: DockerAPI.platformName),
            Components: [
                .init(Name: "Engine", Version: DockerAPI.daemonVersion, Details: details),
                .init(Name: "containerization", Version: RuntimePin.current.containerization, Details: nil),
                .init(Name: "kata", Version: RuntimePin.current.kata, Details: nil),
                .init(Name: "vminit", Version: RuntimePin.current.vminitReference, Details: nil),
            ],
            Version: DockerAPI.daemonVersion,
            ApiVersion: DockerAPI.version,
            MinAPIVersion: DockerAPI.version,
            GitCommit: "dev",
            GoVersion: "swift-6.2",
            Os: "darwin",
            Arch: "arm64",
            KernelVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            Experimental: true,
            BuildTime: ISO8601DateFormatter().string(from: Date())
        )
    }
}

/// `GET /info` — Docker `SystemInfo` (fields `docker info` and the CLI expect).
public struct DockerSystemInfo: Encodable, Sendable {
    public let ID: String
    public let Containers: Int
    public let ContainersRunning: Int
    public let ContainersPaused: Int
    public let ContainersStopped: Int
    public let Images: Int
    public let Driver: String
    public let DriverStatus: [[String]]
    public let DockerRootDir: String
    public let Plugins: PluginsInfo
    public let MemoryLimit: Bool
    public let SwapLimit: Bool
    public let CpuCfsPeriod: Bool
    public let CpuCfsQuota: Bool
    public let CPUShares: Bool
    public let CPUSet: Bool
    public let PidsLimit: Bool
    public let IPv4Forwarding: Bool
    public let Debug: Bool
    public let NFd: Int
    public let NGoroutines: Int
    public let SystemTime: String
    public let LoggingDriver: String
    public let CgroupDriver: String
    public let CgroupVersion: String
    public let NEventsListener: Int
    public let KernelVersion: String
    public let OperatingSystem: String
    public let OSVersion: String
    public let OSType: String
    public let Architecture: String
    public let NCPU: Int
    public let MemTotal: Int64
    public let IndexServerAddress: String
    public let Name: String
    public let Labels: [String]
    public let ExperimentalBuild: Bool
    public let ServerVersion: String
    public let Runtimes: [String: Runtime]
    public let DefaultRuntime: String
    public let Swarm: SwarmInfo
    public let LiveRestoreEnabled: Bool
    public let Isolation: String
    public let InitBinary: String
    public let SecurityOptions: [String]
    public let Warnings: [String]

    public struct PluginsInfo: Encodable, Sendable {
        public let Volume: [String]
        public let Network: [String]
        public let Authorization: [String]
        public let Log: [String]
    }

    public struct Runtime: Encodable, Sendable {
        public let path: String
        public let runtimeArgs: [String]?
    }

    public struct SwarmInfo: Encodable, Sendable {
        public let LocalNodeState: String
        public let NodeID: String
        public let ControlAvailable: Bool
    }

    public init(_ engine: EngineSystemInfo) {
        self.ID = engine.id
        self.Containers = engine.containers
        self.ContainersRunning = engine.containersRunning
        self.ContainersPaused = engine.containersPaused
        self.ContainersStopped = engine.containersStopped
        self.Images = engine.images
        self.Driver = "containerization"
        self.DriverStatus = [
            ["Backing Store", "LocalContentStore"],
            ["Engine", "containerization"],
        ]
        self.DockerRootDir = engine.dockerRootDir
        self.Plugins = .init(Volume: ["local"], Network: ["bridge", "host", "none"], Authorization: [], Log: ["json-file"])
        self.MemoryLimit = true
        self.SwapLimit = false
        self.CpuCfsPeriod = false
        self.CpuCfsQuota = false
        self.CPUShares = true
        self.CPUSet = true
        self.PidsLimit = false
        self.IPv4Forwarding = true
        self.Debug = false
        self.NFd = 0
        self.NGoroutines = 0
        self.SystemTime = ISO8601DateFormatter().string(from: Date())
        self.LoggingDriver = "json-file"
        self.CgroupDriver = "none"
        self.CgroupVersion = "2"
        self.NEventsListener = engine.eventListeners
        self.KernelVersion = engine.kernelVersion
        self.OperatingSystem = engine.operatingSystem
        self.OSVersion = engine.osVersion
        self.OSType = "darwin"
        self.Architecture = engine.architecture
        self.NCPU = engine.ncpu
        self.MemTotal = engine.memTotal
        self.IndexServerAddress = "https://index.docker.io/v1/"
        self.Name = engine.hostname
        self.Labels = []
        self.ExperimentalBuild = true
        self.ServerVersion = DockerAPI.daemonVersion
        self.Runtimes = [
            "containerization": .init(path: "Virtualization.framework", runtimeArgs: nil),
        ]
        self.DefaultRuntime = "containerization"
        self.Swarm = .init(LocalNodeState: "inactive", NodeID: "", ControlAvailable: false)
        self.LiveRestoreEnabled = false
        self.Isolation = "default"
        self.InitBinary = "vminitd"
        self.SecurityOptions = ["name=virtualization"]
        self.Warnings = [
            "WARNING: This is macker, a Docker-compatible API over Apple Containerization",
        ]
    }
}

/// `GET /system/df`.
public struct DockerDiskUsage: Encodable, Sendable {
    public let LayersSize: Int64
    public let Images: [DockerImageSummary]
    public let Containers: [DockerContainerSummary]
    public let Volumes: [DockerVolume]
    public let BuildCache: [EmptyObject]

    public struct EmptyObject: Encodable, Sendable {}

    public init(_ engine: EngineDiskUsage) {
        self.LayersSize = engine.layersSize
        self.Images = engine.images.map(DockerImageSummary.init)
        self.Containers = engine.containers.map(DockerContainerSummary.init)
        self.Volumes = engine.volumes.map { DockerVolume($0, includeUsage: true) }
        self.BuildCache = []
    }
}

/// `GET /events` line.
public struct DockerEvent: Encodable, Sendable {
    public let `Type`: String
    public let Action: String
    public let Actor: Actor
    public let time: Int64
    public let timeNano: Int64

    public struct Actor: Encodable, Sendable {
        public let ID: String
        public let Attributes: [String: String]
    }

    public init(_ event: EngineEvent) {
        self.Type = event.type
        self.Action = event.action
        self.Actor = .init(ID: event.actorID, Attributes: event.attributes)
        self.time = Int64(event.time.timeIntervalSince1970)
        self.timeNano = Int64(event.time.timeIntervalSince1970 * 1_000_000_000)
    }
}

/// `POST /auth` response.
public struct DockerAuthResponse: Encodable, Sendable {
    public let Status: String
    public let IdentityToken: String
}
