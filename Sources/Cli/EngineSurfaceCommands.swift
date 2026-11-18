import ArgumentParser
import Foundation

/// Calls a daemon route that is expected to fail, and prints a Docker-shaped error.
enum EngineSurface {
    static func get(_ path: String) throws -> Never {
        try finish(DaemonAPI.get(path))
    }

    static func post(_ path: String, body: Data? = nil) throws -> Never {
        try finish(DaemonAPI.post(path, body: body))
    }

    static func delete(_ path: String) throws -> Never {
        try finish(DaemonAPI.delete(path))
    }

    static func finish(_ response: UnixHTTPClient.Response) throws -> Never {
        do {
            _ = try DaemonAPI.requireOK(response)
            throw CLIError.http("unexpected success")
        } catch let code as ExitCode {
            throw code
        } catch {
            try DaemonAPI.exitWithDaemonError(error)
        }
    }
}

/// Flags Docker accepts on commands whose daemon call always fails here.
struct IgnoredDockerFlags: ParsableArguments {
    @Argument(parsing: .allUnrecognized)
    var unrecognized: [String] = []
}

// MARK: - Plugin

struct PluginGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins.",
        subcommands: [
            PluginLs.self, PluginInspect.self, PluginInstall.self, PluginEnable.self, PluginDisable.self,
            PluginRm.self, PluginCreate.self, PluginPush.self, PluginSet.self, PluginUpgrade.self,
        ]
    )
}

struct PluginLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List plugins.")

    @Option(name: [.customShort("f"), .long], help: "Filter output based on conditions provided.")
    var filter: [String] = []

    @Option(help: "Format output using a custom template.")
    var format: String?

    @Flag(name: [.customShort("q"), .long], help: "Only display plugin IDs.")
    var quiet = false

    @Flag(name: .customLong("no-trunc"), help: "Don't truncate output.")
    var noTrunc = false

    func run() throws {
        var path = "/plugins"
        if !filter.isEmpty {
            path += "?filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(filter)))"
        }
        let plugins = try DaemonAPI.decode([PluginItem].self, from: DaemonAPI.get(path))
        if quiet || (format != nil && !FormatTemplate.isBareTable(format ?? "")) {
            for plugin in plugins {
                print(noTrunc ? plugin.Id : Format.shortID(plugin.Id))
            }
            return
        }
        Table.print(
            headers: ["ID", "NAME", "DESCRIPTION", "ENABLED"],
            rows: plugins.map { plugin in
                [
                    noTrunc ? plugin.Id : Format.shortID(plugin.Id),
                    plugin.Name,
                    plugin.Config?.Description ?? "",
                    plugin.Enabled == true ? "true" : "false",
                ]
            }
        )
    }

    private struct PluginItem: Decodable {
        var Id: String = ""
        var Name: String = ""
        var Enabled: Bool?
        var Config: Config?
        struct Config: Decodable {
            var Description: String?
        }
    }
}

struct PluginInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more plugins.")
    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template.")
    var format: String?
    @Argument var plugins: [String]
    func run() throws {
        for name in plugins {
            try EngineSurface.get("/plugins/\(DaemonAPI.path(name))/json")
        }
    }
}

struct PluginInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a plugin.")
    @Option(name: .customLong("alias"), help: "Local name for the plugin.")
    var alias: String?
    @Flag(name: .customLong("disable"), help: "Do not enable the plugin on install.")
    var disable = false
    @Flag(name: .customLong("disable-content-trust"), help: "Skip image verification.")
    var disableContentTrust = false
    @Flag(name: .customLong("grant-all-permissions"), help: "Grant all permissions necessary to run the plugin.")
    var grantAllPermissions = false
    @Argument var plugin: String
    @Argument(parsing: .allUnrecognized) var options: [String] = []
    func run() throws {
        try EngineSurface.get("/plugins/privileges?remote=\(DaemonAPI.query(plugin))")
    }
}

struct PluginEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable a plugin.")
    @Option(help: "HTTP client timeout in seconds.")
    var timeout: Int?
    @Argument var plugin: String
    func run() throws { try EngineSurface.post("/plugins/\(DaemonAPI.path(plugin))/enable") }
}

struct PluginDisable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable a plugin.")
    @Flag(name: .shortAndLong, help: "Force the disable of an active plugin.")
    var force = false
    @Argument var plugin: String
    func run() throws { try EngineSurface.post("/plugins/\(DaemonAPI.path(plugin))/disable") }
}

struct PluginRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more plugins.")
    @Flag(name: .shortAndLong, help: "Force the removal of an active plugin.")
    var force = false
    @Argument var plugins: [String]
    func run() throws {
        for name in plugins {
            try EngineSurface.delete("/plugins/\(DaemonAPI.path(name))")
        }
    }
}

struct PluginCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a plugin from a rootfs and configuration.")
    @Flag(name: .customLong("compress"), help: "Compress the context using gzip.")
    var compress = false
    @Argument var plugin: String
    @Argument var path: String
    func run() throws { try EngineSurface.post("/plugins/create?name=\(DaemonAPI.query(plugin))") }
}

struct PluginPush: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Push a plugin to a registry.")
    @Flag(name: .customLong("disable-content-trust"), help: "Skip image signing.")
    var disableContentTrust = false
    @Argument var plugin: String
    func run() throws { try EngineSurface.post("/plugins/\(DaemonAPI.path(plugin))/push") }
}

struct PluginSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change settings for a plugin.")
    @Argument var plugin: String
    @Argument var args: [String]
    func run() throws { try EngineSurface.post("/plugins/\(DaemonAPI.path(plugin))/set") }
}

struct PluginUpgrade: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upgrade", abstract: "Upgrade an existing plugin.")
    @Flag(name: .customLong("disable-content-trust"), help: "Skip image verification.")
    var disableContentTrust = false
    @Flag(name: .customLong("grant-all-permissions"), help: "Grant all permissions necessary to run the plugin.")
    var grantAllPermissions = false
    @Flag(name: .customLong("skip-remote-check"), help: "Do not check if the specified remote matches the existing plugin.")
    var skipRemoteCheck = false
    @Argument var plugin: String
    @Argument var remote: String
    func run() throws { try EngineSurface.post("/plugins/\(DaemonAPI.path(plugin))/upgrade?remote=\(DaemonAPI.query(remote))") }
}

// MARK: - Swarm family

struct SwarmGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swarm",
        abstract: "Manage Swarm.",
        subcommands: [
            SwarmInit.self, SwarmJoin.self, SwarmLeave.self, SwarmUpdate.self,
            SwarmJoinToken.self, SwarmUnlock.self, SwarmUnlockKey.self, SwarmCA.self,
        ]
    )
}

struct SwarmInit: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init", abstract: "Initialize a swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/swarm/init") }
}

struct SwarmJoin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "join", abstract: "Join a swarm as a node and/or manager.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/swarm/join") }
}

struct SwarmLeave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "leave", abstract: "Leave the swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/swarm/leave") }
}

struct SwarmUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update the swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/swarm/update") }
}

struct SwarmJoinToken: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "join-token", abstract: "Manage join tokens.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/swarm") }
}

struct SwarmUnlock: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unlock", abstract: "Unlock swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/swarm/unlock") }
}

struct SwarmUnlockKey: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unlock-key", abstract: "Manage the unlock key.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/swarm/unlockkey") }
}

struct SwarmCA: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ca", abstract: "Display and rotate the root CA.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/swarm") }
}

struct NodeGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "node",
        abstract: "Manage Swarm nodes.",
        subcommands: [
            NodeLs.self, NodeInspect.self, NodePs.self, NodeRm.self, NodeUpdate.self, NodePromote.self, NodeDemote.self,
        ]
    )
}

struct NodeLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List nodes in the swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/nodes") }
}

struct NodeInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more nodes.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/nodes") }
}

struct NodePs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List tasks running on one or more nodes.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/tasks") }
}

struct NodeRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more nodes from the swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.delete("/nodes/none") }
}

struct NodeUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a node.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/nodes/none/update") }
}

struct NodePromote: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "promote", abstract: "Promote one or more nodes to manager in the swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/nodes/none/update") }
}

struct NodeDemote: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "demote", abstract: "Demote one or more nodes from manager in the swarm.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/nodes/none/update") }
}

struct ServiceGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Manage Swarm services.",
        subcommands: [
            ServiceLs.self, ServiceInspect.self, ServicePs.self, ServiceLogs.self, ServiceRm.self,
            ServiceCreate.self, ServiceUpdate.self, ServiceScale.self, ServiceRollback.self,
        ]
    )
}

struct ServiceLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List services.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/services") }
}

struct ServiceInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more services.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/services") }
}

struct ServicePs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List the tasks of one or more services.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/tasks") }
}

struct ServiceLogs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Fetch the logs of a service or task.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/services/none/logs") }
}

struct ServiceRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more services.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.delete("/services/none") }
}

struct ServiceCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new service.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/services/create") }
}

struct ServiceUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a service.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/services/none/update") }
}

struct ServiceScale: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scale", abstract: "Scale one or multiple replicated services.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/services/none/update") }
}

struct ServiceRollback: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rollback", abstract: "Revert changes to a service's configuration.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/services/none/update") }
}

struct SecretGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage Swarm secrets.",
        subcommands: [SecretLs.self, SecretInspect.self, SecretCreate.self, SecretRm.self]
    )
}

struct SecretLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List secrets.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/secrets") }
}

struct SecretInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more secrets.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/secrets") }
}

struct SecretCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a secret from a file or STDIN as content.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/secrets/create") }
}

struct SecretRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more secrets.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.delete("/secrets/none") }
}

struct ConfigGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage Swarm configs.",
        subcommands: [ConfigLs.self, ConfigInspect.self, ConfigCreate.self, ConfigRm.self]
    )
}

struct ConfigLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List configs.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/configs") }
}

struct ConfigInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more configs.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/configs") }
}

struct ConfigCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a config from a file or STDIN.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.post("/configs/create") }
}

struct ConfigRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more configs.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.delete("/configs/none") }
}

struct StackGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stack",
        abstract: "Manage Swarm stacks.",
        subcommands: [StackLs.self, StackPs.self, StackServices.self, StackRm.self, StackDeploy.self, StackConfig.self]
    )
}

struct StackLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List stacks.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/services") }
}

struct StackPs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ps", abstract: "List the tasks in the stack.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/tasks") }
}

struct StackServices: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "services", abstract: "List the services in the stack.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.get("/services") }
}

struct StackRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more stacks.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { try EngineSurface.delete("/services/none") }
}

struct StackDeploy: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deploy", abstract: "Deploy a new stack or update an existing stack.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { throw CLIError.io("Docker Compose is not implemented") }
}

struct StackConfig: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Outputs the final config file, after doing merges and interpolations.")
    @OptionGroup var ignored: IgnoredDockerFlags
    func run() throws { throw CLIError.io("Docker Compose is not implemented") }
}

// MARK: - Checkpoint

struct CheckpointGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkpoint",
        abstract: "Manage checkpoints.",
        subcommands: [CheckpointCreate.self, CheckpointLs.self, CheckpointRm.self]
    )
}

struct CheckpointCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a checkpoint from a running container.")
    @Option(name: .customLong("checkpoint-dir"), help: "Use a custom checkpoint storage directory.")
    var checkpointDir: String?
    @Flag(name: .customLong("leave-running"), help: "Leave the container running after checkpoint.")
    var leaveRunning = false
    @Argument var container: String
    @Argument var checkpoint: String

    func run() throws {
        var path = "/containers/\(DaemonAPI.path(container))/checkpoints"
        if let checkpointDir { path += "?dir=\(DaemonAPI.query(checkpointDir))" }
        let body = try JSONSerialization.data(withJSONObject: ["CheckpointID": checkpoint, "Exit": !leaveRunning])
        try EngineSurface.finish(DaemonAPI.post(path, body: body))
    }
}

struct CheckpointLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List checkpoints for a container.")
    @Option(name: .customLong("checkpoint-dir"), help: "Use a custom checkpoint storage directory.")
    var checkpointDir: String?
    @Argument var container: String

    func run() throws {
        var path = "/containers/\(DaemonAPI.path(container))/checkpoints"
        if let checkpointDir { path += "?dir=\(DaemonAPI.query(checkpointDir))" }
        try EngineSurface.get(path)
    }
}

struct CheckpointRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a checkpoint.")
    @Option(name: .customLong("checkpoint-dir"), help: "Use a custom checkpoint storage directory.")
    var checkpointDir: String?
    @Argument var container: String
    @Argument var checkpoint: String

    func run() throws {
        var path = "/containers/\(DaemonAPI.path(container))/checkpoints/\(DaemonAPI.path(checkpoint))"
        if let checkpointDir { path += "?dir=\(DaemonAPI.query(checkpointDir))" }
        try EngineSurface.delete(path)
    }
}
