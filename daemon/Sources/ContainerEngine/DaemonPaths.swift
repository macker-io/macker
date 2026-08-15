/// Shared filesystem locations used by the daemon and the `macker` CLI.
public enum DaemonPaths: Sendable {
    /// UNIX socket the Docker-compatible API listens on.
    public static let defaultSocketPath = "/tmp/docker-native.sock"

    /// Conventional Docker Engine socket. `macker setup` may symlink this to ``defaultSocketPath``.
    public static let dockerCompatSocketPath = "/var/run/docker.sock"

    /// Value for `docker -H` / `DOCKER_HOST`.
    public static var defaultHostURL: String {
        "unix://\(defaultSocketPath)"
    }
}
