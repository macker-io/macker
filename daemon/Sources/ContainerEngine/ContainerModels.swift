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
        endpoints: [EngineEndpoint] = []
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
    public var memory: Int64
    public var nanoCpus: Int64
    public var autoRemove: Bool
    public var networkMode: String
    public var volumeRequests: [EngineVolumeRequest]
    public var portBindings: [EnginePortBinding]
    public var exposedPorts: [EnginePortBinding]
    public var endpointRequests: [EngineEndpointRequest]

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
        memory: Int64 = 0,
        nanoCpus: Int64 = 0,
        autoRemove: Bool = false,
        networkMode: String = "default",
        volumeRequests: [EngineVolumeRequest] = [],
        portBindings: [EnginePortBinding] = [],
        exposedPorts: [EnginePortBinding] = [],
        endpointRequests: [EngineEndpointRequest] = []
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
        self.memory = memory
        self.nanoCpus = nanoCpus
        self.autoRemove = autoRemove
        self.networkMode = networkMode
        self.volumeRequests = volumeRequests
        self.portBindings = portBindings
        self.exposedPorts = exposedPorts
        self.endpointRequests = endpointRequests
    }
}

/// Full in-process container record backing the Docker Container API.
public struct EngineContainer: Sendable {
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
    public var status: String
    public var created: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int
    public var logs: String
    public var autoRemove: Bool
    public var memory: Int64
    public var nanoCpus: Int64
    public var networkMode: String
    public var tty: Bool
    public var openStdin: Bool
    public var mounts: [EngineMount]
    public var endpoints: [EngineEndpoint] = []
    public var portBindings: [EnginePortBinding] = []
    public var exposedPorts: [EnginePortBinding] = []

    public var summary: EngineContainerSummary {
        EngineContainerSummary(
            id: id,
            names: ["/\(name)"],
            image: image,
            imageID: imageID,
            command: command.joined(separator: " "),
            labels: labels,
            state: state,
            status: status,
            created: created,
            networkMode: networkMode,
            ports: portBindings,
            endpoints: endpoints
        )
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

public struct EngineContainerWaitResult: Sendable {
    public let statusCode: Int
}
