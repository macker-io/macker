import ContainerEngine
import Foundation

/// Docker Engine API versions this daemon serves.
public enum DockerAPI {
    /// Highest version advertised (`/_ping` `Api-Version`, `/version`). Unversioned requests
    /// are served at this version.
    public static let version = "1.44"
    /// Oldest path prefix accepted (`/v1.24/...`), matching what Docker clients still pin.
    public static let minimumVersion = "1.24"
    public static let daemonVersion = ProductVersion.current
    public static let platformName = "macker"

    /// Containers always run as Linux guests, whatever the host is.
    public static let os = "linux"
    /// Docker `/version` uses GOARCH names.
    public static let arch = "arm64"
    /// Docker `/info` uses `uname -m` names.
    public static let machine = "aarch64"
}

/// Numeric `major.minor` Docker API version.
public struct DockerAPIVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init?(_ raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]), major >= 0, minor >= 0 else {
            return nil
        }
        self.init(major: major, minor: minor)
    }

    public static let maximum = DockerAPIVersion(DockerAPI.version)!
    public static let minimum = DockerAPIVersion(DockerAPI.minimumVersion)!

    public var description: String { "\(major).\(minor)" }

    public static func < (lhs: DockerAPIVersion, rhs: DockerAPIVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// `true` when the request was made at `version` or later.
    public func atLeast(_ version: String) -> Bool {
        guard let other = DockerAPIVersion(version) else { return false }
        return self >= other
    }
}

/// Docker's version negotiation rules for a request path prefix.
enum DockerAPIVersionPolicy {
    /// `nil` (unversioned) is served at the maximum. Errors use the daemon's wording.
    static func resolve(_ raw: String?) -> Result<DockerAPIVersion, VersionError> {
        guard let raw else { return .success(.maximum) }
        guard let version = DockerAPIVersion(raw) else {
            return .failure(VersionError(message: "invalid API version: \(raw)"))
        }
        if version > .maximum {
            return .failure(VersionError(
                message: "client version \(raw) is too new. Maximum supported API version is \(DockerAPI.version)"
            ))
        }
        if version < .minimum {
            return .failure(VersionError(
                message: "client version \(raw) is too old. Minimum supported API version is \(DockerAPI.minimumVersion), please upgrade your client to a newer version"
            ))
        }
        return .success(version)
    }

    struct VersionError: Error {
        let message: String
    }
}
