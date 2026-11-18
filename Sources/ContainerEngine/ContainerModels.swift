import Foundation

public struct EngineContainerSummary: Sendable {
    public let id: String
    public let names: [String]
    public let image: String
    public let imageID: String
    public let command: String
    public let labels: [String: String]
    public let state: String
    public let status: String
    public let created: Date
    public let networkMode: String
    public let ports: [EnginePortBinding]
    public let endpoints: [EngineEndpoint]
    public let exitCode: Int
    public let mounts: [EngineMount]
    public var sizeRw: Int64
    public var sizeRootFs: Int64

    public init(
        id: String,
        names: [String],
        image: String,
        imageID: String = "",
        command: String = "",
        labels: [String: String] = [:],
        state: String,
        status: String,
        created: Date,
        networkMode: String = "default",
        ports: [EnginePortBinding] = [],
        endpoints: [EngineEndpoint] = [],
        exitCode: Int = 0,
        mounts: [EngineMount] = [],
        sizeRw: Int64 = -1,
        sizeRootFs: Int64 = -1
    ) {
        self.id = id
        self.names = names
        self.image = image
        self.imageID = imageID
        self.command = command
        self.labels = labels
        self.state = state
        self.status = status
        self.created = created
        self.networkMode = networkMode
        self.ports = ports
        self.endpoints = endpoints
        self.exitCode = exitCode
        self.mounts = mounts
        self.sizeRw = sizeRw
        self.sizeRootFs = sizeRootFs
    }
}

public struct EngineContainerCreateSpec: Sendable {
    public var name: String?
    public var image: String
    public var hostname: String
    public var user: String
    public var env: [String]
    public var cmd: [String]?
    public var entrypoint: [String]?
    public var workingDir: String
    public var labels: [String: String]
    public var tty: Bool
    public var openStdin: Bool
    /// Close the container's stdin when the first attached client closes its stdin.
    public var stdinOnce: Bool
    public var memory: Int64
    public var nanoCpus: Int64
    public var autoRemove: Bool
    public var networkMode: String
    public var volumeRequests: [EngineVolumeRequest]
    public var portBindings: [EnginePortBinding]
    public var exposedPorts: [EnginePortBinding]
    public var endpointRequests: [EngineEndpointRequest]
    public var extraHosts: [String]
    public var dns: [String]
    public var dnsSearch: [String]
    public var dnsOptions: [String]
    public var restartPolicy: EngineRestartPolicy
    public var stopSignal: String
    public var stopTimeout: Int
    public var privileged: Bool
    public var readonlyRootfs: Bool
    public var domainname: String
    public var groupAdd: [String]
    public var publishAllPorts: Bool
    public var volumesFrom: [String]
    public var healthcheck: EngineHealthcheck?
    /// Run a minimal init as PID 1 that forwards signals and reaps zombies.
    public var useInit: Bool
    /// Docker `--cap-add` / `--cap-drop` names (`NET_ADMIN`, `CAP_NET_ADMIN`, `ALL`).
    public var capAdd: [String]
    public var capDrop: [String]
    /// Daemon-owned helper container; not settable through the Docker API.
    var system = false

    public init(
        name: String? = nil,
        image: String,
        hostname: String = "",
        user: String = "",
        env: [String] = [],
        cmd: [String]? = nil,
        entrypoint: [String]? = nil,
        workingDir: String = "",
        labels: [String: String] = [:],
        tty: Bool = false,
        openStdin: Bool = false,
        stdinOnce: Bool = false,
        memory: Int64 = 0,
        nanoCpus: Int64 = 0,
        autoRemove: Bool = false,
        networkMode: String = "default",
        volumeRequests: [EngineVolumeRequest] = [],
        portBindings: [EnginePortBinding] = [],
        exposedPorts: [EnginePortBinding] = [],
        endpointRequests: [EngineEndpointRequest] = [],
        extraHosts: [String] = [],
        dns: [String] = [],
        dnsSearch: [String] = [],
        dnsOptions: [String] = [],
        restartPolicy: EngineRestartPolicy = .none,
        stopSignal: String = "",
        stopTimeout: Int = 0,
        privileged: Bool = false,
        readonlyRootfs: Bool = false,
        domainname: String = "",
        groupAdd: [String] = [],
        publishAllPorts: Bool = false,
        volumesFrom: [String] = [],
        healthcheck: EngineHealthcheck? = nil,
        useInit: Bool = false,
        capAdd: [String] = [],
        capDrop: [String] = []
    ) {
        self.name = name
        self.image = image
        self.hostname = hostname
        self.user = user
        self.env = env
        self.cmd = cmd
        self.entrypoint = entrypoint
        self.workingDir = workingDir
        self.labels = labels
        self.tty = tty
        self.openStdin = openStdin
        self.stdinOnce = stdinOnce
        self.memory = memory
        self.nanoCpus = nanoCpus
        self.autoRemove = autoRemove
        self.networkMode = networkMode
        self.volumeRequests = volumeRequests
        self.portBindings = portBindings
        self.exposedPorts = exposedPorts
        self.endpointRequests = endpointRequests
        self.extraHosts = extraHosts
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.dnsOptions = dnsOptions
        self.restartPolicy = restartPolicy
        self.stopSignal = stopSignal
        self.stopTimeout = stopTimeout
        self.privileged = privileged
        self.readonlyRootfs = readonlyRootfs
        self.domainname = domainname
        self.groupAdd = groupAdd
        self.publishAllPorts = publishAllPorts
        self.volumesFrom = volumesFrom
        self.healthcheck = healthcheck
        self.useInit = useInit
        self.capAdd = capAdd
        self.capDrop = capDrop
    }
}

/// One line (or a partial line flushed at exit) of container output, like a Docker
/// `json-file` log record.
public struct EngineLogEntry: Sendable, Equatable {
    public var time: Date
    public var stdout: Bool
    public var text: String

    public init(time: Date, stdout: Bool, text: String) {
        self.time = time
        self.stdout = stdout
        self.text = text
    }
}

/// When `wait` returns.
public enum EngineWaitCondition: String, Sendable, CaseIterable {
    /// Immediately if the container is not running, else at its next exit.
    case notRunning = "not-running"
    /// At the next exit, even if the container has not started yet.
    case nextExit = "next-exit"
    /// When the container is removed.
    case removed
}

/// Full container record backing the Docker Container API. Persisted as `{store}/containers/{id}.json`.
public struct EngineContainer: Sendable, Codable {
    public var id: String
    public var name: String
    public var image: String
    public var imageID: String
    public var command: [String]
    public var env: [String]
    public var workingDir: String
    public var user: String
    public var hostname: String
    public var labels: [String: String]
    public var state: String
    public var created: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int
    /// In-memory copy of `{id}.log`; not part of the JSON record.
    public var logs: [EngineLogEntry] = []
    public var autoRemove: Bool
    public var memory: Int64
    public var nanoCpus: Int64
    public var networkMode: String
    public var tty: Bool
    public var openStdin: Bool
    public var stdinOnce: Bool = false
    public var mounts: [EngineMount]
    public var endpoints: [EngineEndpoint] = []
    public var portBindings: [EnginePortBinding] = []
    public var exposedPorts: [EnginePortBinding] = []
    public var run: EngineContainerRunConfig = EngineContainerRunConfig()
    public var health: EngineHealthState?

    enum CodingKeys: String, CodingKey {
        case id, name, image, imageID, command, env, workingDir, user, hostname, labels
        case state, created, startedAt, finishedAt, exitCode, autoRemove, memory, nanoCpus
        case networkMode, tty, openStdin, stdinOnce, mounts, endpoints, portBindings, exposedPorts, run, health
    }

    public init(
        id: String,
        name: String,
        image: String,
        imageID: String,
        command: [String],
        env: [String],
        workingDir: String,
        user: String,
        hostname: String,
        labels: [String: String],
        state: String,
        created: Date,
        startedAt: Date?,
        finishedAt: Date?,
        exitCode: Int,
        logs: [EngineLogEntry] = [],
        autoRemove: Bool,
        memory: Int64,
        nanoCpus: Int64,
        networkMode: String,
        tty: Bool,
        openStdin: Bool,
        stdinOnce: Bool = false,
        mounts: [EngineMount],
        endpoints: [EngineEndpoint] = [],
        portBindings: [EnginePortBinding] = [],
        exposedPorts: [EnginePortBinding] = [],
        run: EngineContainerRunConfig = EngineContainerRunConfig(),
        health: EngineHealthState? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.imageID = imageID
        self.command = command
        self.env = env
        self.workingDir = workingDir
        self.user = user
        self.hostname = hostname
        self.labels = labels
        self.state = state
        self.created = created
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.logs = logs
        self.autoRemove = autoRemove
        self.memory = memory
        self.nanoCpus = nanoCpus
        self.networkMode = networkMode
        self.tty = tty
        self.openStdin = openStdin
        self.stdinOnce = stdinOnce
        self.mounts = mounts
        self.endpoints = endpoints
        self.portBindings = portBindings
        self.exposedPorts = exposedPorts
        self.run = run
        self.health = health
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decode(String.self, forKey: .image)
        imageID = try c.decode(String.self, forKey: .imageID)
        command = try c.decode([String].self, forKey: .command)
        env = try c.decode([String].self, forKey: .env)
        workingDir = try c.decode(String.self, forKey: .workingDir)
        user = try c.decode(String.self, forKey: .user)
        hostname = try c.decode(String.self, forKey: .hostname)
        labels = try c.decode([String: String].self, forKey: .labels)
        state = try c.decode(String.self, forKey: .state)
        created = try c.decode(Date.self, forKey: .created)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        exitCode = try c.decode(Int.self, forKey: .exitCode)
        autoRemove = try c.decode(Bool.self, forKey: .autoRemove)
        memory = try c.decode(Int64.self, forKey: .memory)
        nanoCpus = try c.decode(Int64.self, forKey: .nanoCpus)
        networkMode = try c.decode(String.self, forKey: .networkMode)
        tty = try c.decode(Bool.self, forKey: .tty)
        openStdin = try c.decode(Bool.self, forKey: .openStdin)
        stdinOnce = try c.decodeIfPresent(Bool.self, forKey: .stdinOnce) ?? false
        mounts = try c.decode([EngineMount].self, forKey: .mounts)
        endpoints = try c.decodeIfPresent([EngineEndpoint].self, forKey: .endpoints) ?? []
        portBindings = try c.decodeIfPresent([EnginePortBinding].self, forKey: .portBindings) ?? []
        exposedPorts = try c.decodeIfPresent([EnginePortBinding].self, forKey: .exposedPorts) ?? []
        run = try c.decodeIfPresent(EngineContainerRunConfig.self, forKey: .run) ?? EngineContainerRunConfig()
        health = try c.decodeIfPresent(EngineHealthState.self, forKey: .health)
    }

    public var isActive: Bool { state == "running" || state == "paused" }
    public var isSystem: Bool { run.system == true }

    var networkIDs: Set<String> { Set(endpoints.map(\.networkID)) }

    /// Docker `ps` STATUS: `Up 3 minutes`, `Exited (0) 10 seconds ago`.
    public var dockerStatus: String {
        switch state {
        case "created":
            return "Created"
        case "running":
            return "Up \(Self.humanDuration(since: startedAt ?? created))\(Self.healthSuffix(health?.status))"
        case "paused":
            return "Up \(Self.humanDuration(since: startedAt ?? created)) (Paused)"
        case "dead":
            return "Dead"
        default:
            let body = "Exited (\(exitCode))"
            guard let finishedAt else { return body }
            return "\(body) \(Self.humanDuration(since: finishedAt)) ago"
        }
    }

    public var summary: EngineContainerSummary {
        EngineContainerSummary(
            id: id,
            names: ["/\(name)"],
            image: image,
            imageID: imageID,
            command: command.joined(separator: " "),
            labels: labels,
            state: state,
            status: dockerStatus,
            created: created,
            networkMode: networkMode,
            ports: portBindings,
            endpoints: endpoints,
            exitCode: exitCode,
            mounts: mounts
        )
    }

    static func healthSuffix(_ status: String?) -> String {
        switch status {
        case "healthy": return " (healthy)"
        case "unhealthy": return " (unhealthy)"
        case "starting": return " (health: starting)"
        default: return ""
        }
    }

    static func humanDuration(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 1 { return "Less than a second" }
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        let minutes = seconds / 60
        if minutes == 1 { return "About a minute" }
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = Int((Double(seconds) / 3600.0).rounded())
        if hours == 1 { return "About an hour" }
        if hours < 48 { return "\(hours) hours" }
        let days = hours / 24
        if days < 14 { return "\(days) days" }
        let weeks = days / 7
        if weeks < 8 { return "\(weeks) weeks" }
        let months = days / 30
        if months < 24 { return "\(months) months" }
        return "\(days / 365) years"
    }
}

public struct EngineContainerInspect: Sendable {
    public let container: EngineContainer
}

public struct EngineContainerCreateResult: Sendable {
    public let id: String
    public let warnings: [String]
}

public struct EngineContainerTop: Sendable {
    public let titles: [String]
    public let processes: [[String]]
}

public struct EngineContainerStats: Sendable {
    public var read: Date
    public var id: String
    public var name: String
    public var cpuTotal: UInt64
    public var cpuSystem: UInt64
    public var preCPUTotal: UInt64
    public var preCPUSystem: UInt64
    public var onlineCPUs: Int
    public var memoryUsage: UInt64
    public var memoryLimit: UInt64
    public var networks: [String: EngineNetworkIO]
    public var pids: Int
}

public struct EngineNetworkIO: Sendable {
    public var rxBytes: UInt64
    public var txBytes: UInt64
}

public struct EngineContainerWaitResult: Sendable {
    public let statusCode: Int
}
