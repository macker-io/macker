import Foundation

/// Errors thrown by the MicroVM engine adapter.
public enum EngineError: Error, Sendable, LocalizedError {
    case unsupportedHost(String)
    case imageNotFound(String)
    case invalidReference(String)
    case pullFailed(String)
    case pushFailed(String)
    case exportFailed(String)
    case loadFailed(String)
    case notImplemented(String)
    case containerNotFound(String)
    case execNotFound(String)
    case volumeNotFound(String)
    case invalidArgument(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost(let reason),
            .imageNotFound(let reason),
            .invalidReference(let reason),
            .pullFailed(let reason),
            .pushFailed(let reason),
            .exportFailed(let reason),
            .loadFailed(let reason),
            .notImplemented(let reason),
            .containerNotFound(let reason),
            .execNotFound(let reason),
            .volumeNotFound(let reason),
            .invalidArgument(let reason),
            .conflict(let reason):
            return reason
        }
    }
}

/// Host capability report produced by ``EngineManager/checkEnvironment()``.
public struct EnvironmentReport: Sendable {
    public let isAppleSilicon: Bool
    public let isVirtualizationSupported: Bool
    public let macOSVersion: OperatingSystemVersion

    public init(
        isAppleSilicon: Bool,
        isVirtualizationSupported: Bool,
        macOSVersion: OperatingSystemVersion
    ) {
        self.isAppleSilicon = isAppleSilicon
        self.isVirtualizationSupported = isVirtualizationSupported
        self.macOSVersion = macOSVersion
    }
}
