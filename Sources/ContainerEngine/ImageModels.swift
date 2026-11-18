import ContainerizationOCI
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
    public let labels: [String: String]
    public let containers: Int

    public var isDangling: Bool { repoTags.isEmpty }
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
    public let exposedPorts: [EnginePortBinding]
    public let volumes: [String]
    public let shell: [String]
    public let healthcheck: EngineHealthcheck?
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

    /// Docker `GET /images/{name}/history`: newest first; only the top row has an image ID.
    static func from(
        history: [History],
        layerSizes: [Int64],
        imageDigest: String,
        tags: [String]
    ) -> [EngineImageHistoryItem] {
        var remaining = ArraySlice(layerSizes)
        var oldestFirst: [EngineImageHistoryItem] = []
        oldestFirst.reserveCapacity(history.count)
        for (offset, item) in history.enumerated() {
            let empty = item.emptyLayer ?? false
            let newest = offset == history.count - 1
            oldestFirst.append(
                EngineImageHistoryItem(
                    id: newest ? imageDigest : "<missing>",
                    created: Int64((ISO8601.parse(item.created ?? "") ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970),
                    createdBy: item.createdBy ?? "",
                    tags: newest ? tags : [],
                    size: (!empty && !remaining.isEmpty) ? remaining.removeFirst() : 0,
                    comment: item.comment ?? ""
                )
            )
        }
        return Array(oldestFirst.reversed())
    }
}

enum ImageLayerSize {
    static let uncompressedAnnotation = "io.containerd.image.uncompressed"

    static func uncompressed(_ layer: Descriptor, content: Content? = nil) -> Int64 {
        if let raw = layer.annotations?[uncompressedAnnotation], let parsed = Int64(raw) {
            return parsed
        }
        if isGzip(layer.mediaType), let content, let size = gzipISIZE(from: content) {
            return size
        }
        return layer.size
    }

    static func isGzip(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.imageLayerGzip
            || mediaType == MediaTypes.dockerImageLayerGzip
            || mediaType.hasSuffix("+gzip")
            || mediaType.hasSuffix(".gzip")
    }

    static func gzipISIZE(from content: Content) -> Int64? {
        guard let blobSize = try? content.size(), blobSize >= 8 else { return nil }
        guard let header = try? content.data(offset: 0, length: 2) else { return nil }
        guard let tail = try? content.data(offset: blobSize - 4, length: 4) else { return nil }
        guard [UInt8](header) == [0x1f, 0x8b] else { return nil }
        return gzipISIZE(tail)
    }

    static func gzipISIZE(_ tail: Data) -> Int64? {
        let bytes = [UInt8](tail)
        guard bytes.count == 4 else { return nil }
        let value = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Int64(value)
    }
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

/// `POST /images/create?fromSrc=` — filesystem tar becomes a single-layer image.
public struct EngineImportSpec: Sendable {
    public var source: String
    public var repo: String?
    public var tag: String?
    public var message: String
    public var changes: [String]
    public var platform: String?

    public init(
        source: String,
        repo: String? = nil,
        tag: String? = nil,
        message: String = "",
        changes: [String] = [],
        platform: String? = nil
    ) {
        self.source = source
        self.repo = repo
        self.tag = tag
        self.message = message
        self.changes = changes
        self.platform = platform
    }
}
