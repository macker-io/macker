import ContainerEngine
import Foundation

/// Docker error body: `{"message":"..."}`.
public struct DockerErrorResponse: Encodable, Sendable {
    public let message: String
}
