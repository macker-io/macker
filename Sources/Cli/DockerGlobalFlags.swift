import ContainerEngine
import Foundation

/// Docker global flags that apply before the subcommand (`-H`, `--context`, `--config`).
public enum DockerGlobalFlags {
    static func reset() {
        host = nil
        context = nil
        configDirectory = nil
    }

    /// `--host` / `-H` from this invocation. Wins over the environment and the current context.
    nonisolated(unsafe) static var host: String?
    /// `--context` / `-c` from this invocation.
    nonisolated(unsafe) static var context: String?
    /// `--config` directory, otherwise `DOCKER_CONFIG`.
    nonisolated(unsafe) static var configDirectory: URL?

    /// Strips leading global flags and records them. Later flags are left for ArgumentParser.
    public static func install(from arguments: [String]) -> [String] {
        guard let program = arguments.first else { return arguments }
        var kept = [program]
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--" || !arg.hasPrefix("-") || arg == "-" {
                kept.append(contentsOf: rewriteHelpShortFlag(Array(arguments[index...])))
                break
            }
            if arg == "--help" || arg == "--version" || arg == "-v" {
                kept.append(contentsOf: arguments[index...])
                break
            }
            if arg == "-h" {
                kept.append("--help")
                kept.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if let value = consume("--host", "-H", arg, arguments, &index) {
                host = value
                continue
            }
            if let value = consume("--context", "-c", arg, arguments, &index) {
                context = value
                continue
            }
            if let value = consume("--config", nil, arg, arguments, &index) {
                configDirectory = URL(fileURLWithPath: value, isDirectory: true)
                continue
            }
            if consume("--log-level", "-l", arg, arguments, &index) != nil
                || arg == "--debug" || arg == "-D" || arg == "--tls" || arg == "--tlsverify"
            {
                continue
            }
            if consume("--tlscacert", nil, arg, arguments, &index) != nil
                || consume("--tlscert", nil, arg, arguments, &index) != nil
                || consume("--tlskey", nil, arg, arguments, &index) != nil
            {
                continue
            }
            kept.append(contentsOf: arguments[index...])
            break
        }
        return kept
    }

    /// Maps `-h` to `--help` for every subcommand except `run` and `create`,
    /// where `-h` is Docker's short option for `--hostname`.
    private static func rewriteHelpShortFlag(_ rest: [String]) -> [String] {
        let nonFlags = rest.prefix(while: { $0 != "--" }).filter { !$0.hasPrefix("-") }
        let isCreateOrRun: Bool = {
            guard let first = nonFlags.first else { return false }
            if first == "run" || first == "create" { return true }
            if first == "container", nonFlags.dropFirst().first == "run" || nonFlags.dropFirst().first == "create" {
                return true
            }
            return false
        }()
        if isCreateOrRun { return rest }
        var out: [String] = []
        var stop = false
        for arg in rest {
            if stop {
                out.append(arg)
                continue
            }
            if arg == "--" {
                stop = true
                out.append(arg)
                continue
            }
            out.append(arg == "-h" ? "--help" : arg)
        }
        return out
    }

    /// `--host`, then `MACKER_HOST` / `DOCKER_HOST`, then the selected context, then the default socket.
    static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        if let host {
            return try unixSocket(host)
        }
        if environmentHostSet(environment) {
            return DaemonPaths.socketPath(from: environment)
        }
        if let endpoint = try ContextStore.currentEndpoint(environment: environment) {
            return try unixSocket(endpoint)
        }
        return DaemonPaths.defaultSocketPath
    }

    private static func environmentHostSet(_ environment: [String: String]) -> Bool {
        for key in ["MACKER_HOST", "DOCKER_HOST"] {
            if let value = environment[key], DaemonPaths.unixSocketPath(from: value) != nil {
                return true
            }
        }
        return false
    }

    static func unixSocket(_ host: String) throws -> String {
        guard let path = DaemonPaths.unixSocketPath(from: host) else {
            throw CLIError.io("only unix sockets are supported (got \(host))")
        }
        return path
    }

    /// Returns the option value and advances `index` past the flag. `nil` if `arg` is not one of these flags.
    private static func consume(
        _ long: String,
        _ short: String?,
        _ arg: String,
        _ arguments: [String],
        _ index: inout Int
    ) -> String? {
        let names = [long, short].compactMap { $0 }
        for name in names {
            if arg == name {
                let next = index + 1
                guard next < arguments.count else {
                    index = arguments.count
                    return ""
                }
                index = next + 1
                return arguments[next]
            }
            let prefix = name + "="
            if arg.hasPrefix(prefix) {
                index += 1
                return String(arg.dropFirst(prefix.count))
            }
        }
        return nil
    }
}
