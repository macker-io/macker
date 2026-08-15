import Foundation

/// Progress event yielded by ``EngineManager/pullImage(name:tag:platform:)``.
public enum ImagePullEvent: Sendable {
    case status(String, id: String?)
    case progress(id: String, status: String, current: Int64, total: Int64)
}

/// One local image as seen by `GET /images/json`.
public struct EngineImageSummary: Sendable {
    public let id: String
    public let repoTags: [String]
    public let repoDigests: [String]
    public let created: Date
    public let size: Int64
}

/// Low-level inspect payload mapped to Docker `GET /images/{name}/json`.
public struct EngineImageInspect: Sendable {
    public let id: String
    public let repoTags: [String]
    public let repoDigests: [String]
    public let created: String
    public let author: String
    public let architecture: String
    public let os: String
    public let size: Int64
    public let env: [String]
    public let cmd: [String]
    public let entrypoint: [String]
    public let user: String
    public let workingDir: String
    public let labels: [String: String]
    public let layers: [String]
}

/// One item in Docker `DELETE /images/{name}` response.
public struct EngineImageDeleteItem: Sendable {
    public let untagged: String?
    public let deleted: String?
}

public struct EngineImageHistoryItem: Sendable {
    public let id: String
    public let created: Int64
    public let createdBy: String
    public let tags: [String]
    public let size: Int64
    public let comment: String
}

public struct EngineImageSearchResult: Sendable {
    public let name: String
    public let description: String
    public let starCount: Int
    public let isOfficial: Bool
    public let isAutomated: Bool
}

public struct EngineImagePruneResult: Sendable {
    public let deleted: [EngineImageDeleteItem]
    public let spaceReclaimed: Int64
}
