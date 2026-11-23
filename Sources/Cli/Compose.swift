import ArgumentParser
import ContainerEngine
import Darwin
import Foundation

struct Compose: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage Compose projects with the bundled Docker Compose client.",
        helpNames: []
    )
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    func run() throws {
        let fm = FileManager.default
        guard let executable = Bundle.main.executableURL else { throw CLIError.io("cannot locate macker") }
        let tools = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("compose-tools")
        let provider = tools.appendingPathComponent("docker-compose").path
        let plugins = tools.appendingPathComponent("cli-plugins")
        guard fm.isExecutableFile(atPath: provider),
              fm.isExecutableFile(atPath: plugins.appendingPathComponent("docker-buildx").path)
        else {
            throw CLIError.io("Compose tools missing; reinstall the Macker CLI package or run 'make compose-tools' for a debug build")
        }

        // Do not let the official client's ambient Docker context redirect this command.
        var env = ProcessInfo.processInfo.environment
        if DockerGlobalFlags.context == nil {
            env.removeValue(forKey: "DOCKER_CONTEXT")
            env.removeValue(forKey: "DOCKER_CONFIG")
        }
        let endpoint = try DockerGlobalFlags.socketPath(environment: env)

        // Compose discovers Buildx through DOCKER_CONFIG/cli-plugins, not PATH.
        // Keep its writable state separate from both the installation and ~/.docker.
        let root = DockerGlobalFlags.configDirectory ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".macker")
        let config = root.appendingPathComponent("compose")
        try fm.createDirectory(at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = config.appendingPathComponent("cli-plugins")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != plugins.path {
            let tmp = config.appendingPathComponent(UUID().uuidString)
            try fm.createSymbolicLink(atPath: tmp.path, withDestinationPath: plugins.path)
            defer { try? fm.removeItem(at: tmp) }
            guard rename(tmp.path, link.path) == 0 else { throw CLIError.io("cannot link bundled plugins: \(String(cString: strerror(errno)))") }
        }
        unsetenv("DOCKER_CONTEXT")
        unsetenv("DOCKER_CLI_PLUGIN_ORIGINAL_CLI_COMMAND")
        setenv("DOCKER_HOST", "unix://\(endpoint)", 1)
        setenv("DOCKER_CONFIG", config.path, 1)

        // Replace the process to preserve TTYs, signals and the provider's exit code.
        let argv = ([provider] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        execv(provider, argv)
        throw CLIError.io("cannot execute bundled Compose: \(String(cString: strerror(errno)))")
    }
}
