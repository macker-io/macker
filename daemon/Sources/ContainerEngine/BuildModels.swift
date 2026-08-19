import Foundation

/// Parameters for `POST /build`. Shared by the classic backend and the future
/// BuildKit backend (docs/buildkit.md).
public struct EngineBuildSpec: Sendable {
    public var tags: [String]
    public var dockerfile: String
    public var buildArgs: [String: String]
    public var labels: [String: String]
    public var target: String?
    public var noCache: Bool
    public var pull: Bool
    public var quiet: Bool
    public var platform: String?
    public var networkMode: String
    public var extraHosts: [String]
    public var memory: Int64

    public init(
        tags: [String] = [],
        dockerfile: String = BuildContext.defaultDockerfile,
        buildArgs: [String: String] = [:],
        labels: [String: String] = [:],
        target: String? = nil,
        noCache: Bool = false,
        pull: Bool = false,
        quiet: Bool = false,
        platform: String? = nil,
        networkMode: String = "",
        extraHosts: [String] = [],
        memory: Int64 = 0
    ) {
        self.tags = tags
        self.dockerfile = dockerfile.isEmpty ? BuildContext.defaultDockerfile : dockerfile
        self.buildArgs = buildArgs
        self.labels = labels
        self.target = target
        self.noCache = noCache
        self.pull = pull
        self.quiet = quiet
        self.platform = platform
        self.networkMode = networkMode
        self.extraHosts = extraHosts
        self.memory = memory
    }
}

/// Build progress. `status` lines are the `Step 1/4 : …` narration, `output` is raw
/// `RUN` stdio, and `built` closes the stream with the final image digest.
public enum EngineBuildEvent: Sendable {
    case status(String)
    case output(Data)
    case built(String)
}

public struct EngineBuildPruneResult: Sendable {
    public let deleted: [String]
    public let spaceReclaimed: Int64

    public init(deleted: [String], spaceReclaimed: Int64) {
        self.deleted = deleted
        self.spaceReclaimed = spaceReclaimed
    }
}
