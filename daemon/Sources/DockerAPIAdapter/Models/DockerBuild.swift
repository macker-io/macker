import ContainerEngine
import Foundation

/// One newline-delimited line of `POST /build` output.
public struct DockerBuildLine: Encodable, Sendable {
    public let stream: String?
    public let aux: Aux?
    public let error: String?
    public let errorDetail: ErrorDetail?

    public struct Aux: Encodable, Sendable {
        public let ID: String
    }

    public struct ErrorDetail: Encodable, Sendable {
        public let message: String
    }

    public init(stream: String? = nil, aux: Aux? = nil, error: String? = nil, errorDetail: ErrorDetail? = nil) {
        self.stream = stream
        self.aux = aux
        self.error = error
        self.errorDetail = errorDetail
    }

    public static func error(_ message: String) -> DockerBuildLine {
        DockerBuildLine(error: message, errorDetail: .init(message: message))
    }
}

public struct DockerBuildPruneResponse: Encodable, Sendable {
    public let CachesDeleted: [String]
    public let SpaceReclaimed: Int64

    public init(_ result: EngineBuildPruneResult) {
        self.CachesDeleted = result.deleted
        self.SpaceReclaimed = result.spaceReclaimed
    }
}
