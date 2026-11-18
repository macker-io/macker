import ContainerEngine
import CryptoKit
import Foundation

/// Docker context metadata. The default context is implicit and is not stored.
struct DockerContext: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var host: String
    var skipTLSVerify: Bool

    var metaJSON: [String: Any] {
        [
            "Name": name,
            "Metadata": ["Description": description],
            "Endpoints": [
                "docker": [
                    "Host": host,
                    "SkipTLSVerify": skipTLSVerify,
                ]
            ],
        ]
    }
}

/// `~/.docker` when invoked as `docker`, otherwise `~/.macker`. Honors `--config` / `DOCKER_CONFIG`.
enum ContextStore {
    static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        invokedAsDocker: Bool = Invocation.commandName == "docker"
    ) -> URL {
        if let override = DockerGlobalFlags.configDirectory {
            return override
        }
        if let config = environment["DOCKER_CONFIG"], !config.isEmpty {
            return URL(fileURLWithPath: config, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if invokedAsDocker {
            return home.appendingPathComponent(".docker", isDirectory: true)
        }
        return home.appendingPathComponent(".macker", isDirectory: true)
    }

    static func defaultContext(invokedAsDocker: Bool = Invocation.commandName == "docker") -> DockerContext {
        DockerContext(
            name: "default",
            description: "Current DOCKER_HOST, or the default socket",
            host: invokedAsDocker ? "unix://\(DaemonPaths.dockerCompatSocketPath)" : DaemonPaths.defaultHostURL,
            skipTLSVerify: false
        )
    }

    static func currentName(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        root: URL? = nil
    ) -> String {
        if let context = DockerGlobalFlags.context, !context.isEmpty {
            return context
        }
        if let context = environment["DOCKER_CONTEXT"], !context.isEmpty {
            return context
        }
        let directory = root ?? self.root(environment: environment)
        guard let data = try? Data(contentsOf: configFile(in: directory)),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["currentContext"] as? String, !name.isEmpty
        else {
            return "default"
        }
        return name
    }

    /// Endpoint of the selected context, or nil when the implicit default should be used.
    static func currentEndpoint(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        let name = currentName(environment: environment)
        if name == "default" { return nil }
        return try load(name, environment: environment).host
    }

    static func list(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [DockerContext] {
        let directory = root(environment: environment)
        var contexts = [defaultContext()]
        let meta = directory.appendingPathComponent("contexts/meta", isDirectory: true)
        let ids = (try? FileManager.default.contentsOfDirectory(at: meta, includingPropertiesForKeys: nil)) ?? []
        for id in ids {
            let file = id.appendingPathComponent("meta.json")
            guard let context = try? loadMeta(file) else { continue }
            if context.name == "default" { continue }
            contexts.append(context)
        }
        return contexts.sorted { $0.name < $1.name }
    }

    static func load(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DockerContext {
        if name == "default" { return defaultContext() }
        let file = metaFile(name, environment: environment)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CLIError.io("context \(name) not found")
        }
        return try loadMeta(file)
    }

    static func create(
        _ context: DockerContext,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if context.name == "default" {
            throw CLIError.io("context default cannot be created")
        }
        if context.name.isEmpty || context.name.contains("/") || context.name.contains("\0") {
            throw CLIError.io("invalid context name \(context.name)")
        }
        let file = metaFile(context.name, environment: environment)
        if FileManager.default.fileExists(atPath: file.path) {
            throw CLIError.io("context \(context.name) already exists")
        }
        try write(context, to: file)
    }

    static func update(
        name: String,
        description: String?,
        host: String?,
        skipTLSVerify: Bool?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if name == "default" {
            throw CLIError.io("context default cannot be updated")
        }
        var context = try load(name, environment: environment)
        if let description { context.description = description }
        if let host { context.host = host }
        if let skipTLSVerify { context.skipTLSVerify = skipTLSVerify }
        try write(context, to: metaFile(name, environment: environment))
    }

    static func remove(
        _ name: String,
        force: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if name == "default" {
            throw CLIError.io("context default cannot be removed")
        }
        let current = currentName(environment: environment)
        if current == name, !force {
            throw CLIError.io("context \(name) is in use, use -f to force remove")
        }
        let directory = metaFile(name, environment: environment).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw CLIError.io("context \(name) not found")
        }
        try FileManager.default.removeItem(at: directory)
        if current == name {
            try setCurrent("default", environment: environment)
        }
    }

    static func setCurrent(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        _ = try load(name, environment: environment)
        let directory = root(environment: environment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = configFile(in: directory)
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            object = existing
        }
        if name == "default" {
            object.removeValue(forKey: "currentContext")
        } else {
            object["currentContext"] = name
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    /// `destination == nil` writes the tar to stdout.
    static func exportTar(_ name: String, to destination: URL?) throws {
        let context = try load(name)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("macker-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let data = try JSONSerialization.data(withJSONObject: context.metaJSON, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: work.appendingPathComponent("meta.json"))
        let tar = destination ?? work.appendingPathComponent("out.tar")
        if let destination, FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try runTar(["-C", work.path, "-cf", tar.path, "meta.json"])
        if destination == nil {
            FileHandle.standardOutput.write(try Data(contentsOf: tar))
        }
    }

    /// `source == nil` reads the tar from stdin.
    static func importTar(name: String, from source: URL?) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("macker-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        if let source {
            try runTar(["-C", work.path, "-xf", source.path])
        } else {
            try runTar(["-C", work.path, "-xf", "-"], input: FileHandle.standardInput)
        }
        var imported = try loadMeta(work.appendingPathComponent("meta.json"))
        imported.name = name
        try create(imported)
    }

    private static func runTar(
        _ arguments: [String],
        input: FileHandle? = nil,
        output: Pipe? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CLIError.io("tar failed")
        }
    }

    static func endpoint(from dockerFlags: [String]) throws -> (host: String?, skipTLSVerify: Bool?) {
        var host: String?
        var skip: Bool?
        for raw in dockerFlags {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            for part in parts {
                let bits = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard bits.count == 2 else {
                    throw CLIError.io("invalid --docker value \(raw)")
                }
                switch bits[0] {
                case "host":
                    host = bits[1]
                case "skip-tls-verify":
                    skip = ["1", "true", "True"].contains(bits[1])
                default:
                    throw CLIError.io("unknown docker endpoint option \(bits[0])")
                }
            }
        }
        return (host, skip)
    }

    private static func configFile(in root: URL) -> URL {
        root.appendingPathComponent("config.json")
    }

    private static func metaFile(
        _ name: String,
        environment: [String: String]
    ) -> URL {
        root(environment: environment)
            .appendingPathComponent("contexts/meta", isDirectory: true)
            .appendingPathComponent(directoryID(name), isDirectory: true)
            .appendingPathComponent("meta.json")
    }

    static func directoryID(_ name: String) -> String {
        let digest = SHA256Hex.of(Data(name.utf8))
        return digest
    }

    private static func write(_ context: DockerContext, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: context.metaJSON, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    private static func loadMeta(_ file: URL) throws -> DockerContext {
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.io("invalid context metadata \(file.path)")
        }
        let name = object["Name"] as? String ?? ""
        let description = (object["Metadata"] as? [String: Any])?["Description"] as? String ?? ""
        let docker = ((object["Endpoints"] as? [String: Any])?["docker"] as? [String: Any]) ?? [:]
        let host = docker["Host"] as? String ?? ""
        guard !name.isEmpty, !host.isEmpty else {
            throw CLIError.io("invalid context metadata \(file.path)")
        }
        return DockerContext(
            name: name,
            description: description,
            host: host,
            skipTLSVerify: docker["SkipTLSVerify"] as? Bool ?? false
        )
    }
}

enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
