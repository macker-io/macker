import Foundation

/// Shared filesystem locations used by the daemon and the `macker` CLI.
public enum DaemonPaths: Sendable {
    /// Image store, volumes, and the default API socket.
    public static var storeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.macker.daemon", isDirectory: true)
    }

    /// UNIX socket the daemon listens on. Always `macker.sock`, not Docker's name.
    public static var defaultSocketPath: String {
        socketFile(in: storeDirectory)
    }

    /// `macker.sock` under a store directory (including an isolated `--store`).
    public static func socketFile(in storeDirectory: URL) -> String {
        storeDirectory.appendingPathComponent("macker.sock").path
    }

    /// Docker's default socket. `macker setup` may symlink this to ``defaultSocketPath``.
    public static let dockerCompatSocketPath = "/var/run/docker.sock"

    /// Value for `macker` / `DOCKER_HOST` when talking to this daemon directly.
    public static var defaultHostURL: String {
        "unix://\(defaultSocketPath)"
    }

    /// `MACKER_HOST` / `DOCKER_HOST` (`unix://…` or an absolute path), else ``defaultSocketPath``.
    public static func socketPath(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        for key in ["MACKER_HOST", "DOCKER_HOST"] {
            if let value = environment[key], let path = unixSocketPath(from: value) {
                return path
            }
        }
        return defaultSocketPath
    }

    public static func unixSocketPath(from host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("unix://") {
            let path = String(trimmed.dropFirst("unix://".count))
            return path.isEmpty ? nil : path
        }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return nil
    }
}
