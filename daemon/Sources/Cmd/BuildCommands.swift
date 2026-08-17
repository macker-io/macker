import ArgumentParser
import ContainerEngine
import Foundation

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build an image from a Dockerfile.",
        discussion: """
            Classic builder only: BuildKit-specific syntax (RUN --mount, --secret, --ssh,
            heredocs, multi-platform) is not supported.
            """
    )

    @Option(name: [.customShort("t"), .long], help: "Name and optionally a tag (name:tag).")
    var tag: [String] = []

    @Option(name: [.customShort("f"), .customLong("file")], help: "Dockerfile to use (default: PATH/Dockerfile).")
    var file: String?

    @Option(name: .customLong("build-arg"), help: "Set a build-time variable (KEY=VALUE or KEY).")
    var buildArg: [String] = []

    @Option(name: .customLong("label"), help: "Set metadata on the built image (KEY=VALUE).")
    var label: [String] = []

    @Option(help: "Build up to the named stage.")
    var target: String?

    @Option(help: "Platform of the built image (host platform only).")
    var platform: String?

    @Flag(name: .customLong("no-cache"), help: "Do not use cached layers.")
    var noCache = false

    @Flag(help: "Always attempt to pull a newer version of the base image.")
    var pull = false

    @Flag(name: [.customShort("q"), .long], help: "Only print the image ID.")
    var quiet = false

    @Argument(help: "Build context directory.")
    var path: String = "."

    func run() throws {
        let context = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let dockerfile = try Self.contextRelativeDockerfile(file, context: context)

        var query: [String] = ["dockerfile=\(DaemonAPI.query(dockerfile))", "version=1", "rm=1"]
        for item in tag {
            query.append("t=\(DaemonAPI.query(item))")
        }
        if let target, !target.isEmpty {
            query.append("target=\(DaemonAPI.query(target))")
        }
        if let platform, !platform.isEmpty {
            query.append("platform=\(DaemonAPI.query(platform))")
        }
        if noCache { query.append("nocache=1") }
        if pull { query.append("pull=1") }
        if quiet { query.append("q=1") }
        if let encoded = Self.encodeMap(buildArg) {
            query.append("buildargs=\(DaemonAPI.query(encoded))")
        }
        if let encoded = Self.encodeMap(label) {
            query.append("labels=\(DaemonAPI.query(encoded))")
        }

        do {
            try TemporaryDirectory.with("macker-build-context") { work in
                let archive = work.appendingPathComponent("context.tar")
                try BuildContext.pack(root: context, dockerfile: dockerfile, into: archive)
                try Self.stream(path: "/build?\(query.joined(separator: "&"))", context: archive)
            }
        } catch let error as CLIError {
            try DaemonAPI.exitWithDaemonError(error)
        } catch let error as EngineError {
            try DaemonAPI.exitWithDaemonError(error)
        }
    }

    /// `RUN` boots a MicroVM per step, so the client must not time out like a pull does.
    private static func stream(path: String, context: URL) throws {
        var failed: String?
        let status = try DaemonAPI.streamLines(
            method: "POST",
            path: path,
            bodyFile: context,
            contentType: "application/x-tar",
            timeoutSeconds: nil
        ) { line in
            guard let payload = try? JSONDecoder().decode(BuildLine.self, from: Data(line.utf8)) else { return }
            if let error = payload.error, !error.isEmpty {
                failed = error
                return
            }
            guard let text = payload.stream, !text.isEmpty else { return }
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        if let failed {
            try DaemonAPI.exitWithDaemonError(CLIError.http(failed))
        }
        if status != 200 {
            try DaemonAPI.exitWithDaemonError(CLIError.http("request failed with HTTP \(status)"))
        }
    }

    /// Docker requires the Dockerfile to live inside the context; the daemon only
    /// ever sees the tar, so reject escapes here with the same message.
    static func contextRelativeDockerfile(_ file: String?, context: URL) throws -> String {
        guard let file, !file.isEmpty else { return BuildContext.defaultDockerfile }
        let url = URL(fileURLWithPath: file, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
        let root = context.path.hasSuffix("/") ? context.path : context.path + "/"
        guard url.path.hasPrefix(root) else {
            throw CLIError.io("Forbidden path outside the build context: \(file)")
        }
        return String(url.path.dropFirst(root.count))
    }

    /// `KEY=VALUE` pairs to the JSON map Docker's `buildargs` / `labels` expect.
    static func encodeMap(_ items: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        var map: [String: String] = [:]
        for item in items {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard !key.isEmpty else { continue }
            if parts.count > 1 {
                map[key] = String(parts[1])
            } else {
                map[key] = ProcessInfo.processInfo.environment[key] ?? ""
            }
        }
        guard let data = try? JSONEncoder().encode(map) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

struct BuilderGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "builder",
        abstract: "Manage builds.",
        subcommands: [BuilderPrune.self, Build.self]
    )
}

struct BuilderPrune: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove build cache.")

    @Flag(name: [.customShort("f"), .long], help: "Do not prompt for confirmation.")
    var force = false

    func run() throws {
        guard Prompt.confirm("This will remove all build cache.", force: force) else { return }
        let result = try DaemonAPI.decode(
            BuildPruneResponse.self,
            from: DaemonAPI.post("/build/prune", timeoutSeconds: 300)
        )
        for id in result.CachesDeleted ?? [] {
            print(id)
        }
        print("Total reclaimed space: \(Format.size(result.SpaceReclaimed ?? 0))")
    }
}

private struct BuildLine: Decodable {
    var stream: String?
    var error: String?
}

private struct BuildPruneResponse: Decodable {
    var CachesDeleted: [String]?
    var SpaceReclaimed: Int64?
}
