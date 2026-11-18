import ContainerEngine
import Foundation

/// Docker Engine API version this daemon advertises.
public enum DockerAPI {
    /// Newest Engine API this daemon implements.
    public static let version = "1.41"
    /// Oldest versioned prefix accepted. Matches Docker 20.10's `MinAPIVersion`.
    public static let minVersion = "1.24"
    public static let daemonVersion = ProductVersion.current
    public static let platformName = "macker"

    public enum VersionCheck: Equatable, Sendable {
        case supported
        case tooNew
        case tooOld
    }

    /// Compares `1.40` against the supported range. Components are integers, so `1.9` is older than `1.24`.
    public static func check(_ client: String) -> VersionCheck {
        let clientParts = components(client)
        if compare(clientParts, components(version)) == .orderedDescending {
            return .tooNew
        }
        if compare(clientParts, components(minVersion)) == .orderedAscending {
            return .tooOld
        }
        return .supported
    }

    private static func components(_ raw: String) -> [Int] {
        raw.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}
