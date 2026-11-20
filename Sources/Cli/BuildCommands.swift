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

    @Flag(name: .customLong("k3s"), help: "Sync the tagged build result to the running local K3s node.")
    var syncK3s = false

    @Option(help: "Write the image ID to the file.")
    var iidfile: String?

    @Option(help: "Set the networking mode for the RUN instructions during build.")
    var network: String?

    @Option(name: .customLong("add-host"), help: "Add a custom host-to-IP mapping (host:ip).")
    var addHost: [String] = []

    @Option(name: .shortAndLong, help: "Memory limit for RUN (e.g. 128m).")
    var memory: String?

    // Accepted for Docker CLI compatibility; classic builder does not apply these.
    @Option(name: .customLong("cache-from"), help: "Images to consider as cache sources.")
    var cacheFrom: [String] = []

    @Flag(name: .customLong("rm"), inversion: .prefixedNo, help: "Remove intermediate containers after a successful build.")
    var rm = true

    @Flag(name: .customLong("force-rm"), help: "Always remove intermediate containers.")
    var forceRm = false

    @Flag(help: "Compress the build context using gzip.")
    var compress = false

    @Option(name: .customLong("memory-swap"), help: "Swap limit equal to memory plus swap.")
    var memorySwap: String?

    @Option(name: [.customShort("c"), .customLong("cpu-shares")], help: "CPU shares (relative weight).")
    var cpuShares: Int64?

    @Option(name: .customLong("cpu-period"), help: "Limit the CPU CFS period.")
    var cpuPeriod: Int64?

    @Option(name: .customLong("cpu-quota"), help: "Limit the CPU CFS quota.")
    var cpuQuota: Int64?

    @Option(name: .customLong("cpuset-cpus"), help: "CPUs in which to allow execution.")
    var cpusetCpus: String?

    @Option(name: .customLong("cpuset-mems"), help: "MEMs in which to allow execution.")
    var cpusetMems: String?

    @Option(name: .customLong("ulimit"), help: "Ulimit options.")
    var ulimit: [String] = []

    @Option(name: .customLong("shm-size"), help: "Size of /dev/shm.")
    var shmSize: String?

    @Option(name: .customLong("cgroup-parent"), help: "Optional parent cgroup for the container.")
    var cgroupParent: String?

    @Option(name: .customLong("security-opt"), help: "Security options.")
    var securityOpt: [String] = []

    @Option(help: "Container isolation technology.")
    var isolation: String?

    @Flag(help: "Squash newly built layers into a single new layer.")
    var squash = false

    @Flag(name: .customLong("disable-content-trust"), help: "Skip image verification.")
    var disableContentTrust = false

    @Argument(help: "Build context directory.")
    var path: String = "."

    func validate() throws {
        if syncK3s && tag.isEmpty {
            throw ValidationError("--k3s requires at least one --tag")
        }
    }

    func run() throws {
        let context = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let dockerfile = try Self.contextRelativeDockerfile(file, context: context)
        let query = try encodedQuery(dockerfile: dockerfile)

        let imageID: String?
        do {
            imageID = try TemporaryDirectory.with("macker-build-context") { work in
                let archive = work.appendingPathComponent("context.tar")
                try BuildContext.pack(root: context, dockerfile: dockerfile, into: archive)
                return try Self.stream(path: "/build?\(query)", context: archive)
            }
        } catch {
            try DaemonAPI.exitWithDaemonError(error)
        }
        if let iidfile, !iidfile.isEmpty {
            guard let imageID, !imageID.isEmpty else {
                throw CLIError.io("build did not produce an image ID")
            }
            try imageID.write(toFile: iidfile, atomically: true, encoding: .utf8)
        }
        if syncK3s {
            guard let imageID, !imageID.isEmpty else {
                throw CLIError.io("build did not produce an image ID to sync to K3s")
            }
            do {
                try K3s.syncImage(digest: imageID, tags: tag)
            } catch {
                throw CLIError.io("image was built locally, but K3s sync failed: \(error.localizedDescription)")
            }
        }
    }

    func encodedQuery(dockerfile: String) throws -> String {
        if let network, let mode = EngineManager.unsupportedBuildNetwork(network) {
            throw CLIError.io("network mode \(mode) is not implemented")
        }
        for extra in addHost {
            _ = try EngineExtraHost.parse(extra)
        }

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
        if let network, !network.isEmpty {
            query.append("networkmode=\(DaemonAPI.query(network))")
        }
        if !addHost.isEmpty {
            query.append("extrahosts=\(DaemonAPI.query(addHost.joined(separator: ",")))")
        }
        if let memory {
            query.append("memory=\(try DaemonAPI.parseBytes(memory))")
        }
        if let encoded = Self.encodeMap(buildArg) {
            query.append("buildargs=\(DaemonAPI.query(encoded))")
        }
        if let encoded = Self.encodeMap(label) {
            query.append("labels=\(DaemonAPI.query(encoded))")
        }
        return query.joined(separator: "&")
    }

    /// `RUN` boots a MicroVM per step, so the client must not time out like a pull does.
    private static func stream(path: String, context: URL) throws -> String? {
        var failed: String?
        var imageID: String?
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
            if let id = payload.aux?.ID, !id.isEmpty {
                imageID = id
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
        return imageID
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

    @Flag(name: [.customShort("a"), .long], help: "Remove all unused build cache, not just dangling ones.")
    var all = false

    @Option(help: "Filter what to prune (e.g. 'until=24h', 'id=sha256:…').")
    var filter: [String] = []

    // Accepted for Docker CLI compatibility; classic cache has no disk-budget policy.
    @Option(name: .customLong("keep-storage"), help: "Disk space to keep for cache.")
    var keepStorage: String?

    @Option(name: .customLong("reserved-space"), help: "Amount of disk space always reserved.")
    var reservedSpace: String?

    @Option(name: .customLong("max-used-space"), help: "Maximum amount of disk space the cache can occupy.")
    var maxUsedSpace: String?

    @Option(name: .customLong("min-free-space"), help: "Target amount of free disk space.")
    var minFreeSpace: String?

    func run() throws {
        let warning = all
            ? "This will remove all unused build cache."
            : "This will remove all dangling build cache."
        guard Prompt.confirm(warning, force: force) else { return }
        var extra: [String] = []
        if all { extra.append("all=1") }
        let result = try DaemonAPI.decode(
            BuildPruneResponse.self,
            from: DaemonAPI.post(
                try DaemonAPI.filteredPath("/build/prune", filters: filter, extra: extra),
                timeoutSeconds: 300
            )
        )
        for id in result.cachesDeleted ?? [] {
            print(id)
        }
        print("Total reclaimed space: \(Format.size(result.spaceReclaimed ?? 0))")
    }
}

private struct BuildLine: Decodable {
    var stream: String?
    var error: String?
    var aux: Aux?

    struct Aux: Decodable {
        var ID: String?
    }
}

