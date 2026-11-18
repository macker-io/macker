import ContainerEngine
import Foundation

/// `GET /images/json` — Docker `ImageSummary`.
public struct DockerImageSummary: Encodable, Sendable {
    public let Id: String
    public let ParentId: String
    public let RepoTags: [String]
    public let RepoDigests: [String]
    public let Created: Int64
    public let Size: Int64
    public let SharedSize: Int64
    public let VirtualSize: Int64
    public let Labels: [String: String]
    public let Containers: Int

    public init(_ engine: EngineImageSummary) {
        self.Id = engine.id
        self.ParentId = ""
        self.RepoTags = engine.repoTags
        self.RepoDigests = engine.repoDigests
        self.Created = Int64(engine.created.timeIntervalSince1970)
        self.Size = engine.size
        self.SharedSize = -1
        self.VirtualSize = engine.size
        self.Labels = engine.labels
        self.Containers = engine.containers
    }
}

/// `GET /images/{name}/json` — Docker image inspect (subset).
public struct DockerImageInspect: Encodable, Sendable {
    public let Id: String
    public let RepoTags: [String]
    public let RepoDigests: [String]
    public let Parent: String
    public let Comment: String
    public let Created: String
    public let DockerVersion: String
    public let Author: String
    public let Architecture: String
    public let Os: String
    public let Size: Int64
    public let VirtualSize: Int64
    public let GraphDriver: GraphDriver
    public let RootFS: RootFS
    public let Config: ContainerConfig
    public let Metadata: Metadata

    public struct GraphDriver: Encodable, Sendable {
        public let Name: String
        public let Data: [String: String]
    }

    public struct RootFS: Encodable, Sendable {
        public let `Type`: String
        public let Layers: [String]
    }

    public struct ContainerConfig: Encodable, Sendable {
        public let Hostname: String
        public let Domainname: String
        public let User: String
        public let Env: [String]
        public let Cmd: [String]
        public let Image: String
        public let WorkingDir: String
        public let Entrypoint: [String]
        public let Labels: [String: String]
        public let ExposedPorts: [String: EmptyObject]
        public let Volumes: [String: EmptyObject]
        public let Shell: [String]
        public let Healthcheck: Healthcheck?

        public struct EmptyObject: Encodable, Sendable {}

        public struct Healthcheck: Encodable, Sendable {
            public let Test: [String]
            public let Interval: Int64
            public let Timeout: Int64
            public let StartPeriod: Int64
            public let Retries: Int
        }
    }

    public struct Metadata: Encodable, Sendable {
        public let LastTagTime: String
    }

    public init(_ engine: EngineImageInspect) {
        self.Id = engine.id
        self.RepoTags = engine.repoTags
        self.RepoDigests = engine.repoDigests
        self.Parent = ""
        self.Comment = ""
        self.Created = engine.created
        self.DockerVersion = DockerAPI.daemonVersion
        self.Author = engine.author
        self.Architecture = engine.architecture
        self.Os = engine.os
        self.Size = engine.size
        self.VirtualSize = engine.size
        self.GraphDriver = .init(Name: "containerization", Data: [:])
        self.RootFS = .init(Type: "layers", Layers: engine.layers)
        self.Config = .init(
            Hostname: "",
            Domainname: "",
            User: engine.user,
            Env: engine.env,
            Cmd: engine.cmd,
            Image: engine.id,
            WorkingDir: engine.workingDir,
            Entrypoint: engine.entrypoint,
            Labels: engine.labels,
            ExposedPorts: Dictionary(uniqueKeysWithValues: engine.exposedPorts.map { ($0.dockerKey, ContainerConfig.EmptyObject()) }),
            Volumes: Dictionary(uniqueKeysWithValues: engine.volumes.map { ($0, ContainerConfig.EmptyObject()) }),
            Shell: engine.shell,
            Healthcheck: engine.healthcheck.map {
                ContainerConfig.Healthcheck(
                    Test: $0.test,
                    Interval: $0.intervalNanos,
                    Timeout: $0.timeoutNanos,
                    StartPeriod: $0.startPeriodNanos,
                    Retries: $0.retries
                )
            }
        )
        self.Metadata = .init(LastTagTime: engine.created)
    }
}

/// `DELETE /images/{name}` item.
public struct DockerImageDeleteItem: Encodable, Sendable {
    public let Untagged: String?
    public let Deleted: String?

    public init(_ engine: EngineImageDeleteItem) {
        self.Untagged = engine.untagged
        self.Deleted = engine.deleted
    }
}

/// Docker pull progress / error line (newline-delimited JSON).
public struct DockerProgressLine: Encodable, Sendable {
    public let status: String?
    public let id: String?
    public let progressDetail: ProgressDetail?
    public let progress: String?
    public let error: String?
    public let errorDetail: ErrorDetail?

    public struct ProgressDetail: Encodable, Sendable {
        public let current: Int64
        public let total: Int64
    }

    public struct ErrorDetail: Encodable, Sendable {
        public let message: String
    }

    public init(_ event: ImagePullEvent) {
        switch event {
        case .status(let status, let id):
            self.status = status
            self.id = id
            self.progressDetail = nil
            self.progress = nil
            self.error = nil
            self.errorDetail = nil
        case .progress(let id, let status, let current, let total):
            self.status = status
            self.id = id
            self.progressDetail = .init(current: current, total: total)
            self.progress = Self.bar(current: current, total: total)
            self.error = nil
            self.errorDetail = nil
        }
    }

    public static func error(_ message: String) -> DockerProgressLine {
        DockerProgressLine(
            status: nil,
            id: nil,
            progressDetail: nil,
            progress: nil,
            error: message,
            errorDetail: .init(message: message)
        )
    }

    init(
        status: String?,
        id: String?,
        progressDetail: ProgressDetail?,
        progress: String?,
        error: String?,
        errorDetail: ErrorDetail?
    ) {
        self.status = status
        self.id = id
        self.progressDetail = progressDetail
        self.progress = progress
        self.error = error
        self.errorDetail = errorDetail
    }

    private static func bar(current: Int64, total: Int64) -> String {
        guard total > 0 else {
            return formatBytes(current)
        }
        let ratio = min(1.0, Double(current) / Double(total))
        let filled = Int((ratio * 20).rounded())
        let bar = String(repeating: "=", count: max(0, filled - 1)) + (filled > 0 ? ">" : "")
        let empty = String(repeating: " ", count: max(0, 20 - filled))
        return "[\(bar)\(empty)]  \(formatBytes(current, aligningWith: total))/\(formatBytes(total))"
    }

    private static func formatBytes(_ value: Int64, aligningWith other: Int64? = nil) -> String {
        let units: [(String, Double)] = [
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("kB", 1_000),
        ]
        let scale = max(value, other ?? value)
        for (name, size) in units where Double(scale) >= size {
            return String(format: "%.2f%@", Double(value) / size, name)
        }
        return "\(value)B"
    }
}

public struct DockerImageHistoryItem: Encodable, Sendable {
    public let Id: String
    public let Created: Int64
    public let CreatedBy: String
    public let Tags: [String]
    public let Size: Int64
    public let Comment: String

    public init(_ item: EngineImageHistoryItem) {
        self.Id = item.id
        self.Created = item.created
        self.CreatedBy = item.createdBy
        self.Tags = item.tags
        self.Size = item.size
        self.Comment = item.comment
    }
}

public struct DockerImageSearchItem: Encodable, Sendable {
    public let name: String
    public let description: String
    public let star_count: Int
    public let is_official: Bool
    public let is_automated: Bool

    public init(_ item: EngineImageSearchResult) {
        self.name = item.name
        self.description = item.description
        self.star_count = item.starCount
        self.is_official = item.isOfficial
        self.is_automated = item.isAutomated
    }
}

public struct DockerImagePruneResponse: Encodable, Sendable {
    public let ImagesDeleted: [DockerImageDeleteItem]
    public let SpaceReclaimed: Int64

    public init(_ result: EngineImagePruneResult) {
        self.ImagesDeleted = result.deleted.map(DockerImageDeleteItem.init)
        self.SpaceReclaimed = result.spaceReclaimed
    }
}

public struct DockerLoadLine: Encodable, Sendable {
    public let stream: String
}

/// `POST /commit` optional container config overlay.
public struct DockerCommitRequest: Decodable, Sendable {
    public let User: String?
    public let Env: [String]?
    public let Cmd: FlexibleStringList?
    public let Entrypoint: FlexibleStringList?
    public let WorkingDir: String?
    public let Labels: [String: String]?
    public let ExposedPorts: [String: EmptyObject]?
    public let Volumes: [String: EmptyObject]?

    public struct EmptyObject: Decodable, Sendable {}

    public var engineConfig: EngineCommitConfig {
        EngineCommitConfig(
            user: User,
            env: Env,
            cmd: Cmd?.values,
            entrypoint: Entrypoint?.values,
            workingDir: WorkingDir,
            labels: Labels,
            exposedPorts: ExposedPorts.map { Array($0.keys) },
            volumes: Volumes.map { Array($0.keys) }
        )
    }
}

public struct DockerCommitResponse: Encodable, Sendable {
    public let Id: String
}
