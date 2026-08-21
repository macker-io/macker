import Foundation

public enum HelperError: Error, Sendable, LocalizedError, Equatable {
    case notRoot
    case binaryNotFound
    case unauthorized
    case unavailable(String)
    case invalidRequest(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRoot:
            return "root is required"
        case .binaryNotFound:
            return "macker-helper binary not found next to macker; build it with `swift build --product macker-helper`"
        case .unauthorized:
            return "not allowed to configure host routes"
        case .unavailable(let reason), .invalidRequest(let reason), .commandFailed(let reason):
            return reason
        }
    }
}
