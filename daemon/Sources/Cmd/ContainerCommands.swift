import ArgumentParser
import ContainerEngine
import Darwin
import Foundation
import os

struct ContainerCreateOptions: ParsableArguments {
    @Option(help: "Assign a name to the container.")
    var name: String?

    @Option(help: "Container host name.")
    var hostname: String?

    @Option(help: "Container NIS domain name.")
    var domainname: String?

    @Option(name: .shortAndLong, help: "Username or UID (format: <name|uid>[:<group|gid>]).")
    var user: String?

    @Option(name: .customLong("group-add"), help: "Add additional groups to join.")
    var groupAdd: [String] = []

    @Option(name: .shortAndLong, help: "Set environment variables.")
    var env: [String] = []

    @Option(name: .customLong("env-file"), help: "Read in a file of environment variables.")
    var envFile: [String] = []

    @Option(name: .shortAndLong, help: "Working directory inside the container.")
    var workdir: String?

    @Option(help: "Overwrite the default ENTRYPOINT.")
    var entrypoint: String?

    @Option(name: .customLong("label"), help: "Set metadata on a container.")
    var label: [String] = []

    @Option(name: .customLong("label-file"), help: "Read in a line delimited file of labels.")
    var labelFile: [String] = []

    @Flag(name: .shortAndLong, help: "Allocate a pseudo-TTY.")
    var tty = false

    @Flag(name: [.customShort("i"), .long], help: "Keep STDIN open.")
    var interactive = false

    @Option(help: "Memory limit, e.g. 128m.")
    var memory: String?

    @Option(help: "Number of CPUs.")
    var cpus: Double?

    @Option(name: .shortAndLong, help: "Bind mount a volume.")
    var volume: [String] = []

    @Option(help: "Attach a filesystem mount to the container.")
    var mount: [String] = []

    @Option(help: "Mount a tmpfs directory.")
    var tmpfs: [String] = []

    @Option(name: .customLong("volumes-from"), help: "Mount volumes from the specified container(s).")
    var volumesFrom: [String] = []

    @Option(name: .customLong("volume-driver"), help: "Optional volume driver for the container.")
    var volumeDriver: String?

    @Option(name: [.customShort("p"), .customLong("publish")], help: "Publish a container's port(s) to the host.")
    var publish: [String] = []

    @Flag(name: [.customShort("P"), .customLong("publish-all")], help: "Publish all exposed ports to random ports.")
    var publishAll = false

    @Option(help: "Expose a port or a range of ports.")
    var expose: [String] = []

    @Option(name: .customLong("network"), help: "Connect a container to a network.")
    var network: [String] = []

    @Option(help: "IPv4 address (e.g. 172.30.100.104).")
    var ip: String?

    @Option(help: "IPv6 address.")
    var ip6: String?

    @Option(name: .customLong("mac-address"), help: "Container MAC address (not applied to virtio-net).")
    var macAddress: String?

    @Option(name: .customLong("network-alias"), help: "Add network-scoped alias for the container.")
    var networkAlias: [String] = []

    @Option(help: "Add link to another container (legacy; treated as an alias).")
    var link: [String] = []

    @Option(name: .customLong("link-local-ip"), help: "Container IPv4/IPv6 link-local addresses.")
    var linkLocalIP: [String] = []

    @Option(help: "Set custom DNS servers.")
    var dns: [String] = []

    @Option(name: .customLong("dns-search"), help: "Set custom DNS search domains.")
    var dnsSearch: [String] = []

    @Option(name: .customLong("dns-option"), help: "Set DNS options.")
    var dnsOption: [String] = []

    @Option(name: .customLong("add-host"), help: "Add a custom host-to-IP mapping (host:ip).")
    var addHost: [String] = []

    @Option(help: "Restart policy (no, on-failure[:N], always, unless-stopped).")
    var restart: String?

    @Option(help: "Pull image before running (always, missing, never).")
    var pull: String?

    @Option(help: "Set platform if server is multi-platform capable.")
    var platform: String?

    @Option(help: "Write the container ID to the file.")
    var cidfile: String?

    @Flag(name: [.customShort("q"), .long], help: "Suppress the pull output.")
    var quiet = false

    @Flag(help: "Give extended privileges to this container.")
    var privileged = false

    @Flag(name: .customLong("read-only"), help: "Mount the container's root filesystem as read only.")
    var readOnly = false

    @Flag(help: "Run an init inside the container that forwards signals and reaps processes.")
    var `init` = false

    @Option(name: .customLong("stop-signal"), help: "Signal to stop the container.")
    var stopSignal: String?

    @Option(name: .customLong("stop-timeout"), help: "Timeout (in seconds) to stop a container.")
    var stopTimeout: Int?

    @Option(name: .customLong("health-cmd"), help: "Command to run to check health.")
    var healthCmd: String?

    @Option(name: .customLong("health-interval"), help: "Time between running the check (ms|s|m|h).")
    var healthInterval: String?

    @Option(name: .customLong("health-timeout"), help: "Maximum time to allow one check to run (ms|s|m|h).")
    var healthTimeout: String?

    @Option(name: .customLong("health-retries"), help: "Consecutive failures needed to report unhealthy.")
    var healthRetries: Int?

    @Option(name: .customLong("health-start-period"), help: "Start period for the container to initialize before counting retries.")
    var healthStartPeriod: String?

    @Option(name: .customLong("health-start-interval"), help: "Time between running the check during the start period.")
    var healthStartInterval: String?

    @Flag(name: .customLong("no-healthcheck"), help: "Disable any container-specified HEALTHCHECK.")
    var noHealthcheck = false

    @Option(name: .customLong("log-driver"), help: "Logging driver for the container.")
    var logDriver: String?

    @Option(name: .customLong("log-opt"), help: "Log driver options.")
    var logOpt: [String] = []

    @Option(name: [.customShort("c"), .customLong("cpu-shares")], help: "CPU shares (relative weight).")
    var cpuShares: Int64?

    @Option(name: .customLong("cpu-period"), help: "Limit CPU CFS period.")
    var cpuPeriod: Int64?

    @Option(name: .customLong("cpu-quota"), help: "Limit CPU CFS quota.")
    var cpuQuota: Int64?

    @Option(name: .customLong("cpuset-cpus"), help: "CPUs in which to allow execution.")
    var cpusetCpus: String?

    @Option(name: .customLong("cpuset-mems"), help: "MEMs in which to allow execution.")
    var cpusetMems: String?

    @Option(name: .customLong("memory-reservation"), help: "Memory soft limit.")
    var memoryReservation: String?

    @Option(name: .customLong("memory-swap"), help: "Swap limit equal to memory plus swap.")
    var memorySwap: String?

    @Option(name: .customLong("memory-swappiness"), help: "Tune container memory swappiness (0 to 100).")
    var memorySwappiness: Int64?

    @Option(name: .customLong("pids-limit"), help: "Tune container pids limit.")
    var pidsLimit: Int64?

    @Option(name: .customLong("ulimit"), help: "Ulimit options.")
    var ulimit: [String] = []

    @Option(name: .customLong("shm-size"), help: "Size of /dev/shm.")
    var shmSize: String?

    @Option(help: "Add Linux capabilities.")
    var capAdd: [String] = []

    @Option(help: "Drop Linux capabilities.")
    var capDrop: [String] = []

    @Option(name: .customLong("security-opt"), help: "Security options.")
    var securityOpt: [String] = []

    @Option(name: .customLong("cgroup-parent"), help: "Optional parent cgroup for the container.")
    var cgroupParent: String?

    @Option(help: "Cgroup namespace to use (host|private).")
    var cgroupns: String?

    @Option(help: "User namespace to use.")
    var userns: String?

    @Option(help: "PID namespace to use.")
    var pid: String?

    @Option(help: "IPC mode to use.")
    var ipc: String?

    @Option(help: "UTS namespace to use.")
    var uts: String?

    @Option(help: "Container isolation technology.")
    var isolation: String?

    @Option(help: "Add a host device to the container.")
    var device: [String] = []

    @Option(help: "GPU devices to add to the container.")
    var gpus: String?

    @Option(name: .customLong("device-cgroup-rule"), help: "Add a rule to the cgroup allowed devices list.")
    var deviceCgroupRule: [String] = []

    @Option(help: "Sysctl options.")
    var sysctl: [String] = []

    @Option(help: "Runtime to use for this container.")
    var runtime: String?

    @Option(name: .customLong("storage-opt"), help: "Storage driver options for the container.")
    var storageOpt: [String] = []

    @Option(help: "Add an annotation.")
    var annotation: [String] = []

    @Flag(name: .customLong("oom-kill-disable"), help: "Disable OOM Killer.")
    var oomKillDisable = false

    @Option(name: .customLong("oom-score-adj"), help: "Tune host's OOM preferences (-1000 to 1000).")
    var oomScoreAdj: Int?

    @Option(name: .customLong("blkio-weight"), help: "Block IO (relative weight), between 10 and 1000.")
    var blkioWeight: UInt16?

    @Option(name: .customLong("blkio-weight-device"), help: "Block IO weight (relative device weight).")
    var blkioWeightDevice: [String] = []

    @Option(name: .customLong("device-read-bps"), help: "Limit read rate (bytes per second) from a device.")
    var deviceReadBps: [String] = []

    @Option(name: .customLong("device-read-iops"), help: "Limit read rate (IO per second) from a device.")
    var deviceReadIops: [String] = []

    @Option(name: .customLong("device-write-bps"), help: "Limit write rate (bytes per second) to a device.")
    var deviceWriteBps: [String] = []

    @Option(name: .customLong("device-write-iops"), help: "Limit write rate (IO per second) to a device.")
    var deviceWriteIops: [String] = []

    @Option(name: .customLong("kernel-memory"), help: "Kernel memory limit (deprecated, ignored).")
    var kernelMemory: String?

    @Flag(name: .customLong("disable-content-trust"), help: "Skip image verification (ignored; no content trust).")
    var disableContentTrust = false

    @Argument(help: "Image reference.")
    var image: String

    @Argument(parsing: .captureForPassthrough, help: "Command to run.")
    var command: [String] = []
}

struct ContainerListOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Show all containers (default hides stopped).")
    var all = false

    @Flag(name: [.customShort("q"), .long], help: "Only display container IDs.")
    var quiet = false

    @Option(name: [.customShort("f"), .long], help: "Filter output (e.g. 'status=running', 'label=key=value').")
    var filter: [String] = []

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Option(name: [.customShort("n"), .customLong("last")], help: "Show n last created containers (includes all states).")
    var last: Int?

    @Flag(name: [.customShort("l"), .customLong("latest")], help: "Show the latest created container (includes all states).")
    var latest = false

    @Flag(name: .customLong("no-trunc"), help: "Don't truncate output.")
    var noTrunc = false

    @Flag(name: .shortAndLong, help: "Display total file sizes.")
    var size = false
}

struct Ps: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List containers.")

    @OptionGroup var options: ContainerListOptions

    func run() throws { try Self.list(options) }

    static func list(_ options: ContainerListOptions) throws {
        var query: [String] = []
        let all = options.all || options.latest || options.last != nil
        if all { query.append("all=1") }
        if options.size { query.append("size=1") }
        if options.latest {
            query.append("limit=1")
        } else if let last = options.last {
            query.append("limit=\(max(last, 0))")
        }
        if !options.filter.isEmpty {
            query.append("filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(options.filter)))")
        }
        let path = query.isEmpty ? "/containers/json" : "/containers/json?\(query.joined(separator: "&"))"
        let containers = try DaemonAPI.decode([ContainerSummary].self, from: DaemonAPI.get(path))

        if options.quiet {
            for container in containers {
                print(options.noTrunc ? container.Id : Format.shortID(container.Id))
            }
            return
        }

        let rows: [[(String, String)]] = containers.map { container in
            let name = (container.Names.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let labels = (container.Labels ?? [:]).keys.sorted().map { key in
                "\(key)=\(container.Labels?[key] ?? "")"
            }.joined(separator: ",")
            let size: String
            if let bytes = container.SizeRw, bytes >= 0 {
                size = Format.size(bytes)
            } else {
                size = ""
            }
            return [
                ("ID", options.noTrunc ? container.Id : Format.shortID(container.Id)),
                ("Image", container.Image),
                ("Command", options.noTrunc ? container.Command : Format.ellipsis(container.Command, 20)),
                ("CreatedAt", Format.createdAt(container.Created ?? 0)),
                ("RunningFor", Format.timeAgo(container.Created ?? 0)),
                ("Ports", container.portsColumn),
                ("Status", container.Status),
                ("Size", size),
                ("Names", name),
                ("Labels", labels),
                ("Mounts", (container.Mounts ?? []).map(\.Destination).joined(separator: ",")),
                ("Networks", (container.NetworkSettings?.Networks ?? [:]).keys.sorted().joined(separator: ",")),
                ("State", container.State ?? ""),
            ]
        }

        if let format = options.format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, rows: rows)
            return
        }

        func value(_ key: String, _ row: [(String, String)]) -> String {
            row.first { $0.0 == key }?.1 ?? ""
        }
        var headers = ["CONTAINER ID", "IMAGE", "COMMAND", "STATUS", "PORTS", "NAMES"]
        if options.size { headers.append("SIZE") }
        Table.print(headers: headers, rows: rows.map { row in
            var cells = [
                value("ID", row), value("Image", row), value("Command", row),
                value("Status", row), value("Ports", row), value("Names", row),
            ]
            if options.size { cells.append(value("Size", row)) }
            return cells
        })
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create and start a container.")

    @Flag(name: .shortAndLong, help: "Run in the background and print the container ID.")
    var detach = false

    @Flag(help: "Automatically remove the container when it exits.")
    var rm = false

    @Option(name: .shortAndLong, help: "Attach to STDIN, STDOUT or STDERR.")
    var attach: [String] = []

    @Option(name: .customLong("detach-keys"), help: "Override the key sequence for detaching a container.")
    var detachKeys: String?

    @Flag(name: .customLong("sig-proxy"), inversion: .prefixedNo, help: "Proxy received signals to the process.")
    var sigProxy = true

    @OptionGroup var options: ContainerCreateOptions

    func run() throws {
        try Create.rejectRestartWithAutoRemove(restart: options.restart, autoRemove: rm)
        let id = try Create.submit(options, autoRemove: rm && detach)
        if let cidfile = options.cidfile, !cidfile.isEmpty {
            try id.write(toFile: cidfile, atomically: true, encoding: .utf8)
        }
        if detach {
            try DaemonAPI.requireOK(DaemonAPI.post("/containers/\(DaemonAPI.path(id))/start", timeoutSeconds: 300))
            print(id)
            return
        }
        let streams = Self.streams(attach: attach, interactive: options.interactive)
        try ContainerAttach.attachAndStart(
            id: id,
            stdin: streams.stdin,
            stdout: streams.stdout,
            stderr: streams.stderr,
            tty: options.tty,
            detachKeys: detachKeys,
            sigProxy: sigProxy,
            deleteOnFailure: true
        )
        let wait = try DaemonAPI.decode(
            WaitResponse.self,
            from: DaemonAPI.post("/containers/\(DaemonAPI.path(id))/wait", timeoutSeconds: nil)
        )
        if rm {
            _ = try? DaemonAPI.delete("/containers/\(DaemonAPI.path(id))?force=1&v=1")
        }
        if wait.StatusCode != 0 {
            throw ExitCode(Int32(truncatingIfNeeded: wait.StatusCode))
        }
    }

    static func streams(attach: [String], interactive: Bool) -> (stdin: Bool, stdout: Bool, stderr: Bool) {
        if attach.isEmpty {
            return (interactive, true, true)
        }
        let names = Set(attach.map { $0.lowercased() })
        return (
            names.contains("stdin") || names.contains("i"),
            names.contains("stdout") || names.contains("o"),
            names.contains("stderr") || names.contains("e")
        )
    }
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new container.")

    @OptionGroup var options: ContainerCreateOptions

    func run() throws {
        let id = try Self.submit(options, autoRemove: false)
        if let cidfile = options.cidfile, !cidfile.isEmpty {
            try id.write(toFile: cidfile, atomically: true, encoding: .utf8)
        }
        print(id)
    }

    static func rejectRestartWithAutoRemove(restart: String?, autoRemove: Bool) throws {
        guard autoRemove else { return }
        let policy = try restart.map { try EngineRestartPolicy.parse($0) } ?? .none
        if policy != .none {
            throw CLIError.io("Conflicting options: --restart and --rm")
        }
    }

    static func submit(_ options: ContainerCreateOptions, autoRemove: Bool) throws -> String {
        try rejectRestartWithAutoRemove(restart: options.restart, autoRemove: autoRemove)
        if let ip6 = options.ip6, !ip6.isEmpty {
            throw CLIError.io("IPv6 is not implemented")
        }
        let env = try DaemonAPI.envFile(options.envFile) + options.env
        var labels = try DaemonAPI.labelFile(options.labelFile)
        for item in options.label {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            labels[key] = parts.count == 2 ? parts[1] : ""
        }
        let networks = try Self.networks(options)
        let restart = try options.restart.map { try EngineRestartPolicy.parse($0) } ?? .none
        var host = CreateBody.HostConfig(
            AutoRemove: autoRemove ? true : nil,
            Memory: nil,
            NanoCpus: options.cpus.map { Int64(($0 * 1_000_000_000).rounded()) },
            Binds: options.volume.isEmpty ? nil : options.volume,
            Mounts: try Self.mounts(options.mount),
            Tmpfs: options.tmpfs.isEmpty ? nil : Dictionary(uniqueKeysWithValues: options.tmpfs.map { ($0.split(separator: ":").first.map(String.init) ?? $0, "") }),
            VolumesFrom: options.volumesFrom.isEmpty ? nil : options.volumesFrom,
            VolumeDriver: options.volumeDriver,
            NetworkMode: networks.mode,
            PortBindings: try Self.portBindings(options.publish),
            PublishAllPorts: options.publishAll ? true : nil,
            Privileged: options.privileged ? true : nil,
            ReadonlyRootfs: options.readOnly ? true : nil,
            Dns: options.dns.isEmpty ? nil : options.dns,
            DnsSearch: options.dnsSearch.isEmpty ? nil : options.dnsSearch,
            DnsOptions: options.dnsOption.isEmpty ? nil : options.dnsOption,
            ExtraHosts: options.addHost.isEmpty ? nil : options.addHost,
            RestartPolicy: restart.name == "no" ? nil : .init(Name: restart.name, MaximumRetryCount: restart.maximumRetryCount),
            StopSignal: options.stopSignal,
            StopTimeout: options.stopTimeout,
            GroupAdd: options.groupAdd.isEmpty ? nil : options.groupAdd
        )
        if let memory = options.memory {
            host.Memory = try DaemonAPI.parseBytes(memory)
        }
        var exposed: [String: CreateBody.Empty] = [:]
        for spec in options.expose {
            let binding = try EnginePortBinding.parseExposed(spec)
            exposed[binding.dockerKey] = .init()
        }
        let body = CreateBody(
            Hostname: options.hostname,
            Domainname: options.domainname,
            User: options.user,
            Image: options.image,
            Cmd: options.command.isEmpty ? nil : options.command,
            Env: env.isEmpty ? nil : env,
            Entrypoint: options.entrypoint.map { [$0] },
            WorkingDir: options.workdir,
            Labels: labels.isEmpty ? nil : labels,
            Tty: options.tty ? true : nil,
            OpenStdin: options.interactive ? true : nil,
            ExposedPorts: exposed.isEmpty ? nil : exposed,
            Healthcheck: try Self.healthcheck(options),
            HostConfig: host,
            NetworkingConfig: networks.endpoints.isEmpty ? nil : .init(EndpointsConfig: networks.endpoints)
        )
        try Self.pullIfNeeded(options)
        var path = "/containers/create"
        if let name = options.name, !name.isEmpty {
            path += "?name=\(DaemonAPI.query(name))"
        }
        let payload = try JSONEncoder().encode(body)
        let created: CreateResponse
        if let existing = try Self.create(path: path, payload: payload) {
            created = existing
        } else {
            if (options.pull ?? "missing") == "never" {
                throw CLIError.http("No such image: \(options.image)")
            }
            let (name, tag) = DaemonAPI.splitReference(options.image)
            print("Unable to find image '\(name):\(tag)' locally")
            try Pull.submit(options.image, platform: options.platform, quiet: options.quiet)
            guard let retry = try Self.create(path: path, payload: payload) else {
                throw CLIError.http("No such image: \(options.image)")
            }
            created = retry
        }
        for warning in created.Warnings ?? [] {
            fputs("WARNING: \(warning)\n", stderr)
        }
        return created.Id
    }

    private static func pullIfNeeded(_ options: ContainerCreateOptions) throws {
        switch options.pull ?? "missing" {
        case "always":
            try Pull.submit(options.image, platform: options.platform, quiet: options.quiet)
        case "missing", "never":
            return
        default:
            throw CLIError.io("invalid --pull value \(options.pull ?? "")")
        }
    }

    private static func networks(_ options: ContainerCreateOptions) throws -> (mode: String?, endpoints: [String: CreateBody.EndpointConfig]) {
        var specs = try options.network.map { try EngineNetworkAttachSpec.parse($0) }
        if specs.isEmpty {
            specs = [EngineNetworkAttachSpec(name: "default")]
        }
        if let ip = options.ip, specs[0].ipv4 == nil {
            specs[0].ipv4 = ip
        }
        if let mac = options.macAddress, specs[0].macAddress == nil {
            specs[0].macAddress = mac
        }
        specs[0].aliases.append(contentsOf: options.networkAlias)
        for item in options.link {
            let alias = item.split(separator: ":").last.map(String.init) ?? item
            if !alias.isEmpty { specs[0].aliases.append(alias) }
        }
        specs[0].linkLocalIPs.append(contentsOf: options.linkLocalIP)
        let mode = specs[0].name == "default" ? nil : specs[0].name
        var endpoints: [String: CreateBody.EndpointConfig] = [:]
        for spec in specs {
            endpoints[spec.name] = try Self.endpointConfig(spec)
        }
        if endpoints.count == 1, specs[0].name == "default", options.ip == nil, options.networkAlias.isEmpty, options.link.isEmpty, options.macAddress == nil, options.linkLocalIP.isEmpty {
            return (mode, [:])
        }
        return (mode, endpoints)
    }

    private static func endpointConfig(_ spec: EngineNetworkAttachSpec) throws -> CreateBody.EndpointConfig {
        let request = try spec.asRequest()
        let ipam: CreateBody.IPAMConfig?
        if request.ipv4 != nil || !spec.linkLocalIPs.isEmpty {
            ipam = .init(
                IPv4Address: request.ipv4,
                IPv6Address: nil,
                LinkLocalIPs: spec.linkLocalIPs.isEmpty ? nil : spec.linkLocalIPs
            )
        } else {
            ipam = nil
        }
        return CreateBody.EndpointConfig(
            Aliases: request.aliases.isEmpty ? nil : request.aliases,
            Links: nil,
            IPAMConfig: ipam,
            DriverOpts: nil,
            GwPriority: nil,
            MacAddress: request.macAddress
        )
    }

    private static func mounts(_ specs: [String]) throws -> [CreateBody.Mount]? {
        guard !specs.isEmpty else { return nil }
        return try specs.map { spec in
            let parsed = try EngineVolumeSpec.parseMount(spec)
            return CreateBody.Mount(Type: parsed.type, Source: parsed.source.isEmpty ? nil : parsed.source, Target: parsed.destination, ReadOnly: parsed.readOnly)
        }
    }

    private static func healthcheck(_ options: ContainerCreateOptions) throws -> CreateBody.Healthcheck? {
        if options.noHealthcheck {
            return .init(Test: ["NONE"], Interval: nil, Timeout: nil, StartPeriod: nil, StartInterval: nil, Retries: nil)
        }
        guard let cmd = options.healthCmd else { return nil }
        func nanos(_ raw: String?) throws -> Int64? {
            guard let raw else { return nil }
            guard let duration = ISO8601.parseGoDuration(raw) else {
                throw CLIError.io("invalid duration: \(raw)")
            }
            return Int64(duration * 1_000_000_000)
        }
        return .init(
            Test: ["CMD-SHELL", cmd],
            Interval: try nanos(options.healthInterval),
            Timeout: try nanos(options.healthTimeout),
            StartPeriod: try nanos(options.healthStartPeriod),
            StartInterval: try nanos(options.healthStartInterval),
            Retries: options.healthRetries
        )
    }

    private static func create(path: String, payload: Data) throws -> CreateResponse? {
        let response = try DaemonAPI.post(path, body: payload)
        if DaemonAPI.isMissingImage(response) {
            return nil
        }
        return try DaemonAPI.decode(CreateResponse.self, from: response)
    }

    private static func portBindings(_ specs: [String]) throws -> [String: [CreateBody.PortBinding]]? {
        guard !specs.isEmpty else { return nil }
        var mapped: [String: [CreateBody.PortBinding]] = [:]
        for spec in specs {
            let binding = try EnginePortBinding.parsePublish(spec)
            mapped[binding.dockerKey, default: []].append(
                .init(HostIp: binding.hostIP, HostPort: binding.hostPort == 0 ? "" : String(binding.hostPort))
            )
        }
        return mapped
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start one or more stopped containers.")

    @Flag(name: [.customShort("a"), .long], help: "Attach STDOUT/STDERR and forward signals.")
    var attach = false

    @Flag(name: [.customShort("i"), .long], help: "Attach container's STDIN.")
    var interactive = false

    @Option(name: .customLong("detach-keys"), help: "Override the key sequence for detaching a container.")
    var detachKeys: String?

    @Argument var containers: [String]

    func run() throws {
        if attach || interactive {
            guard containers.count == 1 else {
                throw CLIError.io("you cannot start and attach multiple containers at once")
            }
            let id = containers[0]
            let info = try DaemonAPI.decode(
                AttachInspect.self,
                from: DaemonAPI.get("/containers/\(DaemonAPI.path(id))/json")
            )
            try ContainerAttach.attachAndStart(
                id: id,
                stdin: interactive,
                stdout: true,
                stderr: true,
                tty: info.Config.Tty == true,
                detachKeys: detachKeys
            )
            let wait = try DaemonAPI.decode(
                WaitResponse.self,
                from: DaemonAPI.post("/containers/\(DaemonAPI.path(id))/wait", timeoutSeconds: nil)
            )
            if wait.StatusCode != 0 {
                throw ExitCode(Int32(truncatingIfNeeded: wait.StatusCode))
            }
            return
        }
        try ContainerAction.post("start", containers, timeoutSeconds: 300)
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop one or more running containers.")
    @Option(name: .shortAndLong, help: "Seconds to wait before killing the container.")
    var time: Int?

    @Option(help: "Signal to send to the container.")
    var signal: String?

    @Argument var containers: [String]
    func run() throws {
        var parts: [String] = []
        if let time { parts.append("t=\(time)") }
        if let signal { parts.append("signal=\(DaemonAPI.query(signal))") }
        try ContainerAction.post("stop", containers, query: parts.joined(separator: "&"), timeoutSeconds: (time ?? 10) + 30)
    }
}

struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart one or more containers.")
    @Option(name: .shortAndLong, help: "Seconds to wait before killing the container.")
    var time: Int = 10
    @Argument var containers: [String]
    func run() throws { try ContainerAction.post("restart", containers, query: "t=\(time)", timeoutSeconds: time + 30) }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Kill one or more running containers.")
    @Option(name: .shortAndLong, help: "Signal to send.")
    var signal: String = "KILL"
    @Argument var containers: [String]
    func run() throws { try ContainerAction.post("kill", containers, query: "signal=\(DaemonAPI.query(signal))", timeoutSeconds: 30) }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause all processes within one or more containers.")
    @Argument var containers: [String]
    func run() throws { try ContainerAction.post("pause", containers) }
}

struct Unpause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unpause all processes within one or more containers.")
    @Argument var containers: [String]
    func run() throws { try ContainerAction.post("unpause", containers) }
}

struct Rm: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove one or more containers.")
    @Flag(name: .shortAndLong, help: "Force the removal of a running container.")
    var force = false
    @Flag(name: .customShort("v"), help: "Remove anonymous volumes.")
    var volumes = false
    @Flag(name: [.customShort("l"), .long], help: "Remove the specified link (legacy; no-op).")
    var link = false
    @Argument var containers: [String]
    func run() throws { try Self.remove(containers, force: force, volumes: volumes, link: link) }

    static func remove(_ containers: [String], force: Bool, volumes: Bool, link: Bool = false) throws {
        if link {
            for id in containers {
                print(id)
            }
            return
        }
        for id in containers {
            var path = "/containers/\(DaemonAPI.path(id))?"
            if force { path += "force=1&" }
            if volumes { path += "v=1&" }
            try DaemonAPI.requireOK(DaemonAPI.delete(path))
            print(id)
        }
    }
}

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a container.")
    @Argument var container: String
    @Argument var newName: String
    func run() throws {
        try DaemonAPI.requireOK(
            DaemonAPI.post("/containers/\(DaemonAPI.path(container))/rename?name=\(DaemonAPI.query(newName))")
        )
    }
}

struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command in a running container.")

    @Flag(name: [.customShort("i"), .long], help: "Keep STDIN open.")
    var interactive = false

    @Flag(name: .shortAndLong, help: "Allocate a pseudo-TTY.")
    var tty = false

    @Flag(name: .shortAndLong, help: "Detached mode: run command in the background.")
    var detach = false

    @Option(name: .shortAndLong, help: "Username or UID.")
    var user: String?

    @Option(name: .shortAndLong, help: "Working directory inside the container.")
    var workdir: String?

    @Option(name: .shortAndLong, help: "Set environment variables.")
    var env: [String] = []

    @Flag(help: "Give extended privileges to the command.")
    var privileged = false

    @Option(name: .customLong("detach-keys"), help: "Override the key sequence for detaching a container.")
    var detachKeys: String?

    @Option(name: .customLong("env-file"), help: "Read in a file of environment variables.")
    var envFile: [String] = []

    @Argument(help: "Container name or ID.")
    var container: String

    @Argument(parsing: .captureForPassthrough, help: "Command to run.")
    var command: [String] = []

    func run() throws {
        guard !command.isEmpty else {
            throw CLIError.http("No command specified")
        }
        do {
            try runExec()
        } catch {
            try DaemonAPI.exitWithDaemonError(error)
        }
    }

    private func runExec() throws {
        // Inspect first so "no such container" wins over TTY/start errors, matching Docker CLI.
        _ = try DaemonAPI.requireOK(DaemonAPI.get("/containers/\(DaemonAPI.path(container))/json"))
        let env = try DaemonAPI.envFile(envFile) + env
        let created = try DaemonAPI.decode(
            ExecCreateResponse.self,
            from: DaemonAPI.post(
                "/containers/\(DaemonAPI.path(container))/exec",
                body: try JSONEncoder().encode(
                    ExecCreateBody(
                        AttachStdin: interactive,
                        AttachStdout: true,
                        AttachStderr: true,
                        DetachKeys: detachKeys,
                        Tty: tty,
                        Env: env.isEmpty ? nil : env,
                        Cmd: command,
                        Privileged: privileged,
                        User: user,
                        WorkingDir: workdir
                    )
                )
            )
        )
        let start = try JSONEncoder().encode(ExecStartBody(Detach: detach, Tty: tty))
        if detach {
            try DaemonAPI.requireOK(DaemonAPI.post("/exec/\(DaemonAPI.path(created.Id))/start", body: start))
            return
        }
        let proxy = ProcessSignalProxy(
            enabled: !tty,
            killPath: "/exec/\(DaemonAPI.path(created.Id))/kill"
        )
        defer { proxy.restore() }
        let keys: [UInt8]? = interactive ? (try detachKeys.map(DetachKeys.parse) ?? DetachKeys.default) : nil
        try DaemonAPI.hijack(
            path: "/exec/\(DaemonAPI.path(created.Id))/start",
            body: start,
            stdin: interactive,
            tty: tty,
            resizePath: tty ? "/exec/\(DaemonAPI.path(created.Id))/resize" : nil,
            detachKeys: keys
        )
        let inspect = try DaemonAPI.decode(
            ExecInspectResponse.self,
            from: DaemonAPI.get("/exec/\(DaemonAPI.path(created.Id))/json")
        )
        if inspect.Running { return }
        if let code = inspect.ExitCode, code != 0 {
            throw ExitCode(Int32(truncatingIfNeeded: code))
        }
    }
}

struct Attach: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach local standard input, output, and error streams to a running container."
    )

    @Flag(name: .customLong("no-stdin"), help: "Do not attach STDIN.")
    var noStdin = false

    @Flag(name: .customLong("sig-proxy"), inversion: .prefixedNo, help: "Proxy received signals to the process.")
    var sigProxy = true

    @Option(name: .customLong("detach-keys"), help: "Override the key sequence for detaching a container.")
    var detachKeys: String?

    @Argument var container: String

    func run() throws {
        let info: AttachInspect
        do {
            info = try DaemonAPI.decode(
                AttachInspect.self,
                from: DaemonAPI.get("/containers/\(DaemonAPI.path(container))/json")
            )
        } catch {
            try DaemonAPI.exitWithDaemonError(error)
        }
        if info.State.Paused == true {
            throw CLIError.http("You cannot attach to a paused container, unpause it first")
        }
        if info.State.Running != true {
            throw CLIError.http("You cannot attach to a stopped container, start it first")
        }

        let tty = info.Config.Tty == true
        let stdin = !noStdin && info.Config.OpenStdin == true
        var query = "stream=1&stdout=1&stderr=1"
        if stdin { query += "&stdin=1" }

        let keys: [UInt8]?
        if stdin {
            keys = try detachKeys.map(DetachKeys.parse) ?? DetachKeys.default
        } else {
            keys = nil
        }

        let proxy = ProcessSignalProxy(
            enabled: sigProxy && !tty,
            killPath: "/containers/\(DaemonAPI.path(container))/kill"
        )
        defer { proxy.restore() }

        do {
            try DaemonAPI.hijack(
                path: "/containers/\(DaemonAPI.path(container))/attach?\(query)",
                stdin: stdin,
                tty: tty,
                resizePath: tty ? "/containers/\(DaemonAPI.path(container))/resize" : nil,
                detachKeys: keys
            )
            let after = try DaemonAPI.decode(
                AttachInspect.self,
                from: DaemonAPI.get("/containers/\(DaemonAPI.path(container))/json")
            )
            if after.State.Running == true { return }
            if let code = after.State.ExitCode, code != 0 {
                throw ExitCode(Int32(truncatingIfNeeded: code))
            }
        } catch let code as ExitCode {
            throw code
        } catch {
            try DaemonAPI.exitWithDaemonError(error)
        }
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch the logs of a container.")
    @Flag(name: .shortAndLong, help: "Follow log output.")
    var follow = false
    @Flag(name: .shortAndLong, help: "Show timestamps.")
    var timestamps = false
    @Option(name: [.customShort("n"), .customLong("tail")], help: "Number of lines to show from the end of the logs.")
    var tail: String?
    @Option(help: "Show logs since timestamp (RFC3339 or Unix) or duration (e.g. 42m).")
    var since: String?
    @Option(help: "Show logs before timestamp (RFC3339 or Unix) or duration (e.g. 42m).")
    var until: String?
    @Flag(help: "Show extra details provided to logs.")
    var details = false
    @Argument var container: String

    func run() throws {
        try Self.printLogs(
            id: container,
            follow: follow,
            timestamps: timestamps,
            tail: tail,
            since: since,
            until: until,
            details: details
        )
    }

    static func printLogs(
        id: String,
        follow: Bool,
        timestamps: Bool,
        tail: String?,
        since: String? = nil,
        until: String? = nil,
        details: Bool = false
    ) throws {
        var path = "/containers/\(DaemonAPI.path(id))/logs?stdout=1&stderr=1"
        if follow { path += "&follow=1" }
        if timestamps { path += "&timestamps=1" }
        if details { path += "&details=1" }
        if let tail { path += "&tail=\(DaemonAPI.query(tail))" }
        if let since { path += "&since=\(DaemonAPI.query(since))" }
        if let until { path += "&until=\(DaemonAPI.query(until))" }
        let status = try DaemonAPI.streamBytes(
            method: "GET",
            path: path,
            timeoutSeconds: follow ? nil : 15
        ) { DockerLog.write($0) }
        if status >= 400 {
            throw CLIError.http("logs failed with HTTP \(status)")
        }
    }
}

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Block until one or more containers stop, then print their exit codes.")
    @Argument var containers: [String]
    func run() throws {
        for id in containers {
            let wait = try DaemonAPI.decode(
                WaitResponse.self,
                from: DaemonAPI.post("/containers/\(DaemonAPI.path(id))/wait", timeoutSeconds: nil)
            )
            print(wait.StatusCode)
        }
    }
}

struct Top: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display the running processes of a container.")

    @Option(name: .customLong("ps-args"), help: "Arguments to pass to ps.")
    var psArgs: String?

    @Argument var container: String

    @Argument(parsing: .allUnrecognized, help: "Arguments to pass to ps.")
    var ps: [String] = []

    func run() throws {
        var path = "/containers/\(DaemonAPI.path(container))/top"
        let args = ps.isEmpty ? psArgs : ps.joined(separator: " ")
        if let args, !args.isEmpty {
            path += "?ps_args=\(DaemonAPI.query(args))"
        }
        let top = try DaemonAPI.decode(TopResponse.self, from: DaemonAPI.get(path))
        Table.print(headers: top.Titles, rows: top.Processes)
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display a live stream of container resource usage statistics.")

    @Flag(name: .customLong("no-stream"), help: "Disable streaming stats and only pull the first result.")
    var noStream = false

    @Flag(name: [.customShort("a"), .long], help: "Show all containers (default hides stopped).")
    var all = false

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Flag(name: .customLong("no-trunc"), help: "Don't truncate output.")
    var noTrunc = false

    @Argument var containers: [String] = []

    func run() throws {
        let ids = try Self.resolve(containers, all: all)
        guard !ids.isEmpty else {
            if format == nil || FormatTemplate.isBareTable(format ?? "table") {
                Table.print(headers: Self.headers, rows: [])
            }
            return
        }
        if noStream {
            try Self.printSnapshot(ids: ids, format: format, noTrunc: noTrunc)
            return
        }
        var printed = 0
        while true {
            let rows = try ids.map { try Self.fields(for: $0, noTrunc: noTrunc) }
            if let format, !FormatTemplate.isBareTable(format) {
                try FormatTemplate.print(format: format, rows: rows)
            } else {
                Self.redraw(
                    headers: Self.headers,
                    rows: rows.map { Self.cells($0) },
                    previousRows: printed
                )
                printed = 1 + rows.count
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private static let headers = [
        "CONTAINER ID", "NAME", "CPU %", "MEM USAGE / LIMIT", "MEM %", "NET I/O", "PIDS",
    ]

    private static func resolve(_ names: [String], all: Bool) throws -> [String] {
        if !names.isEmpty { return names }
        let path = all ? "/containers/json?all=1" : "/containers/json"
        let running = try DaemonAPI.decode([ContainerSummary].self, from: DaemonAPI.get(path))
        return running.map(\.Id)
    }

    private static func printSnapshot(ids: [String], format: String?, noTrunc: Bool) throws {
        let rows = try ids.map { try fields(for: $0, noTrunc: noTrunc) }
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, rows: rows)
            return
        }
        Table.print(headers: headers, rows: rows.map { cells($0) })
    }

    private static func fields(for id: String, noTrunc: Bool) throws -> [(String, String)] {
        let stats: StatsResponse
        do {
            stats = try DaemonAPI.decode(
                StatsResponse.self,
                from: DaemonAPI.get("/containers/\(DaemonAPI.path(id))/stats?stream=0", timeoutSeconds: 15)
            )
        } catch {
            return zeroFields(id: id, noTrunc: noTrunc)
        }
        return stats.fields(noTrunc: noTrunc)
    }

    private static func zeroFields(id: String, noTrunc: Bool) -> [(String, String)] {
        [
            ("ID", noTrunc ? id : Format.shortID(id)),
            ("Name", id),
            ("CPUPerc", "0.00%"),
            ("MemUsage", "0B / 0B"),
            ("MemPerc", "0.00%"),
            ("NetIO", "0B / 0B"),
            ("BlockIO", "0B / 0B"),
            ("PIDs", "0"),
        ]
    }

    private static func cells(_ row: [(String, String)]) -> [String] {
        ["ID", "Name", "CPUPerc", "MemUsage", "MemPerc", "NetIO", "PIDs"].map { key in
            row.first { $0.0 == key }?.1 ?? ""
        }
    }

    private static func redraw(headers: [String], rows: [[String]], previousRows: Int) {
        if previousRows > 0, isatty(STDOUT_FILENO) != 0 {
            fputs("\u{001B}[\(previousRows)A", stdout)
        }
        Table.print(headers: headers, rows: rows)
        fflush(stdout)
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Return low-level information on Docker objects.")

    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Flag(name: .shortAndLong, help: "Display total file sizes if the type is container.")
    var size = false

    @Option(help: "Return JSON for a specified type (container, image, volume, network).")
    var type: String?

    @Argument var names: [String]
    func run() throws {
        try Self.inspect(names, prefer: try Self.kind(type) ?? .auto, format: format, size: size)
    }

    private static func kind(_ type: String?) throws -> Kind? {
        guard let type, !type.isEmpty else { return nil }
        switch type {
        case "container": return .container
        case "image": return .image
        case "volume": return .volume
        case "network": return .network
        default: throw CLIError.io("unknown type: \(type)")
        }
    }

    enum Kind {
        case auto, image, container, volume, network

        var searchOrder: [Kind] {
            switch self {
            case .image: [.image]
            case .container: [.container]
            case .volume: [.volume]
            case .network: [.network]
            case .auto: [.container, .image, .volume, .network]
            }
        }

        func path(for name: String, verbose: Bool = false, size: Bool = false) -> String? {
            switch self {
            case .container:
                let path = "/containers/\(DaemonAPI.path(name))/json"
                return size ? "\(path)?size=1" : path
            case .image:
                return "/images/\(DaemonAPI.path(name))/json"
            case .volume:
                return "/volumes/\(DaemonAPI.path(name))"
            case .network:
                let path = "/networks/\(DaemonAPI.path(name))"
                return verbose ? "\(path)?verbose=1" : path
            case .auto:
                return nil
            }
        }
    }

    static func inspect(
        _ names: [String],
        prefer: Kind,
        format: String? = nil,
        verbose: Bool = false,
        size: Bool = false
    ) throws {
        let objects = try names.map { try fetch($0, prefer: prefer, verbose: verbose, size: size) }
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, objects: objects)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func fetch(_ name: String, prefer: Kind, verbose: Bool, size: Bool) throws -> Any {
        var lastError: Error = CLIError.http("no such object: \(name)")
        for kind in prefer.searchOrder {
            guard let path = kind.path(for: name, verbose: verbose, size: size) else { continue }
            do {
                let response = try DaemonAPI.get(path)
                if response.statusCode == 404 { continue }
                return try JSONSerialization.jsonObject(with: try DaemonAPI.requireOK(response).body)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

struct Port: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List port mappings or a specific mapping for the container."
    )

    @Argument(help: "Container name or ID.")
    var container: String

    @Argument(help: "Private port, optionally with protocol (for example 80 or 80/tcp).")
    var privatePort: String?

    func run() throws {
        let inspect = try DaemonAPI.decode(
            DockerPortMapping.Inspect.self,
            from: DaemonAPI.get("/containers/\(DaemonAPI.path(container))/json")
        )
        for line in try DockerPortMapping.lines(from: inspect, privatePort: privatePort, container: container) {
            print(line)
        }
    }
}

struct ContainerPrune: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove all stopped containers.")

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var force = false

    @Option(help: "Filter what to prune (e.g. 'until=24h', 'label=key=value').")
    var filter: [String] = []

    func run() throws {
        guard Prompt.confirm("This will remove all stopped containers.", force: force) else { return }
        var path = "/containers/prune"
        if !filter.isEmpty {
            path += "?filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(filter)))"
        }
        let result = try DaemonAPI.decode(ContainerPruneResponse.self, from: DaemonAPI.post(path))
        if let ids = result.ContainersDeleted, !ids.isEmpty {
            print("Deleted Containers:")
            for id in ids {
                print(id)
            }
        }
        print("Total reclaimed space: \(Format.size(result.SpaceReclaimed ?? 0))")
    }
}

struct ContainerGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "Manage containers.",
        subcommands: [
            ContainerLs.self, Run.self, Create.self, Start.self, Stop.self, Restart.self, Kill.self,
            ContainerRm.self, Pause.self, Unpause.self, Rename.self, Logs.self, Wait.self, Top.self,
            Stats.self, Attach.self, Exec.self, Cp.self, Export.self, Diff.self, Commit.self, ContainerInspect.self, Port.self,
            ContainerPrune.self,
        ]
    )
}

struct ContainerLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List containers.")
    @OptionGroup var options: ContainerListOptions
    func run() throws { try Ps.list(options) }
}

struct ContainerRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more containers.")
    @Flag(name: .shortAndLong) var force = false
    @Flag(name: .customShort("v")) var volumes = false
    @Flag(name: [.customShort("l"), .long], help: "Remove the specified link (legacy; no-op).")
    var link = false
    @Argument var containers: [String]
    func run() throws { try Rm.remove(containers, force: force, volumes: volumes, link: link) }
}

struct ContainerInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Display detailed information on one or more containers."
    )

    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Flag(name: .shortAndLong, help: "Display total file sizes.")
    var size = false

    @Argument var containers: [String]
    func run() throws { try Inspect.inspect(containers, prefer: .container, format: format, size: size) }
}

private enum ContainerAction {
    static func post(_ action: String, _ ids: [String], query: String = "", timeoutSeconds: Int? = 5) throws {
        for id in ids {
            var path = "/containers/\(DaemonAPI.path(id))/\(action)"
            if !query.isEmpty { path += "?\(query)" }
            try DaemonAPI.requireOK(DaemonAPI.post(path, timeoutSeconds: timeoutSeconds))
            print(id)
        }
    }
}

private enum ContainerAttach {
    static func attachAndStart(
        id: String,
        stdin: Bool,
        stdout: Bool = true,
        stderr: Bool = true,
        tty: Bool,
        detachKeys: String? = nil,
        sigProxy: Bool = true,
        deleteOnFailure: Bool = false
    ) throws {
        var parts = ["stream=1"]
        if stdout { parts.append("stdout=1") }
        if stderr { parts.append("stderr=1") }
        if stdin { parts.append("stdin=1") }
        let query = parts.joined(separator: "&")
        let keys: [UInt8]?
        if stdin {
            keys = try detachKeys.map(DetachKeys.parse) ?? DetachKeys.default
        } else {
            keys = nil
        }
        let gate = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let attachError = OSAllocatedUnfairLock<Error?>(uncheckedState: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DaemonAPI.hijack(
                    path: "/containers/\(DaemonAPI.path(id))/attach?\(query)",
                    stdin: stdin,
                    tty: tty,
                    resizePath: tty ? "/containers/\(DaemonAPI.path(id))/resize" : nil,
                    onUpgraded: { gate.signal() },
                    detachKeys: keys
                )
            } catch {
                attachError.withLock { $0 = error }
                gate.signal()
            }
            done.signal()
        }
        gate.wait()
        if let error = attachError.withLock({ $0 }) {
            if deleteOnFailure {
                _ = try? DaemonAPI.delete("/containers/\(DaemonAPI.path(id))?force=1&v=1")
            }
            done.wait()
            throw error
        }
        let interrupt = ProcessSignalProxy(enabled: sigProxy && !tty, signals: [(SIGINT, "SIGINT")]) { _ in
            _ = try? DaemonAPI.post("/containers/\(DaemonAPI.path(id))/stop?t=1")
        }
        defer { interrupt.restore() }
        do {
            try DaemonAPI.requireOK(DaemonAPI.post("/containers/\(DaemonAPI.path(id))/start", timeoutSeconds: 300))
        } catch {
            if deleteOnFailure {
                _ = try? DaemonAPI.delete("/containers/\(DaemonAPI.path(id))?force=1&v=1")
            }
            done.wait()
            throw error
        }
        done.wait()
    }
}

private struct ContainerSummary: Decodable {
    var Id: String
    var Names: [String]
    var Image: String
    var Command: String
    var Created: Int64?
    var Status: String
    var State: String?
    var Labels: [String: String]?
    var SizeRw: Int64?
    var Ports: [Port]?
    var Mounts: [Mount]?
    var NetworkSettings: NetworkSettings?

    struct Port: Decodable {
        var IP: String?
        var PrivatePort: Int
        var PublicPort: Int?
        var `Type`: String?
    }

    struct Mount: Decodable {
        var Destination: String
    }

    struct NetworkSettings: Decodable {
        var Networks: [String: Empty]?
        struct Empty: Decodable {}
    }

    var portsColumn: String {
        EnginePortBinding.psColumn(
            (Ports ?? []).map {
                EnginePortBinding(
                    hostIP: $0.IP ?? "",
                    hostPort: $0.PublicPort ?? 0,
                    containerPort: $0.PrivatePort,
                    protocolName: $0.`Type` ?? "tcp"
                )
            }
        )
    }
}

private struct CreateBody: Encodable {
    var Hostname: String?
    var Domainname: String?
    var User: String?
    var Image: String
    var Cmd: [String]?
    var Env: [String]?
    var Entrypoint: [String]?
    var WorkingDir: String?
    var Labels: [String: String]?
    var Tty: Bool?
    var OpenStdin: Bool?
    var ExposedPorts: [String: Empty]?
    var Healthcheck: Healthcheck?
    var HostConfig: HostConfig?
    var NetworkingConfig: NetworkingConfig?

    struct Empty: Encodable {}

    struct Healthcheck: Encodable {
        var Test: [String]?
        var Interval: Int64?
        var Timeout: Int64?
        var StartPeriod: Int64?
        var StartInterval: Int64?
        var Retries: Int?
    }

    struct HostConfig: Encodable {
        var AutoRemove: Bool?
        var Memory: Int64?
        var NanoCpus: Int64?
        var Binds: [String]?
        var Mounts: [Mount]?
        var Tmpfs: [String: String]?
        var VolumesFrom: [String]?
        var VolumeDriver: String?
        var NetworkMode: String?
        var PortBindings: [String: [PortBinding]]?
        var PublishAllPorts: Bool?
        var Privileged: Bool?
        var ReadonlyRootfs: Bool?
        var Dns: [String]?
        var DnsSearch: [String]?
        var DnsOptions: [String]?
        var ExtraHosts: [String]?
        var RestartPolicy: RestartPolicy?
        var StopSignal: String?
        var StopTimeout: Int?
        var GroupAdd: [String]?
    }

    struct RestartPolicy: Encodable {
        var Name: String
        var MaximumRetryCount: Int
    }

    struct Mount: Encodable {
        var `Type`: String?
        var Source: String?
        var Target: String?
        var ReadOnly: Bool?
    }

    struct PortBinding: Encodable {
        var HostIp: String
        var HostPort: String
    }

    struct NetworkingConfig: Encodable {
        var EndpointsConfig: [String: EndpointConfig]
    }

    struct EndpointConfig: Encodable {
        var Aliases: [String]?
        var Links: [String]?
        var IPAMConfig: IPAMConfig?
        var DriverOpts: [String: String]?
        var GwPriority: Int?
        var MacAddress: String?
    }

    struct IPAMConfig: Encodable {
        var IPv4Address: String?
        var IPv6Address: String?
        var LinkLocalIPs: [String]?
    }
}

private struct CreateResponse: Decodable {
    var Id: String
    var Warnings: [String]?
}

private struct AttachInspect: Decodable {
    var Config: Config
    var State: State

    struct Config: Decodable {
        var Tty: Bool?
        var OpenStdin: Bool?
    }

    struct State: Decodable {
        var Running: Bool?
        var Paused: Bool?
        var ExitCode: Int?
    }
}

private struct WaitResponse: Decodable {
    var StatusCode: Int
}

private struct ExecCreateBody: Encodable {
    var AttachStdin: Bool
    var AttachStdout: Bool
    var AttachStderr: Bool
    var DetachKeys: String?
    var Tty: Bool
    var Env: [String]?
    var Cmd: [String]
    var Privileged: Bool
    var User: String?
    var WorkingDir: String?
}

private struct ExecCreateResponse: Decodable {
    var Id: String
}

private struct ExecStartBody: Encodable {
    var Detach: Bool
    var Tty: Bool
}

private struct ExecInspectResponse: Decodable {
    var Running: Bool
    var ExitCode: Int?
}

private struct TopResponse: Decodable {
    var Titles: [String]
    var Processes: [[String]]
}

private struct StatsResponse: Decodable {
    var id: String
    var name: String
    var cpu_stats: CPU
    var precpu_stats: CPU
    var memory_stats: Memory
    var networks: [String: Net]?
    var pids_stats: Pids?

    struct CPU: Decodable {
        var cpu_usage: Usage
        var system_cpu_usage: UInt64?
        var online_cpus: Int?
        struct Usage: Decodable { var total_usage: UInt64 }
    }

    struct Memory: Decodable {
        var usage: UInt64
        var limit: UInt64
    }

    struct Net: Decodable {
        var rx_bytes: UInt64
        var tx_bytes: UInt64
    }

    struct Pids: Decodable {
        var current: Int
    }

    func fields(noTrunc: Bool) -> [(String, String)] {
        let cpuDelta = Double(cpu_stats.cpu_usage.total_usage) - Double(precpu_stats.cpu_usage.total_usage)
        let sysDelta = Double(cpu_stats.system_cpu_usage ?? 0) - Double(precpu_stats.system_cpu_usage ?? 0)
        let cpus = Double(max(cpu_stats.online_cpus ?? 1, 1))
        let cpuPercent = sysDelta > 0 ? cpuDelta / sysDelta * cpus * 100 : 0
        let limit = max(memory_stats.limit, 1)
        let memPercent = Double(memory_stats.usage) / Double(limit) * 100
        let rx = networks?.values.reduce(UInt64(0)) { $0 + $1.rx_bytes } ?? 0
        let tx = networks?.values.reduce(UInt64(0)) { $0 + $1.tx_bytes } ?? 0
        let name = self.name.hasPrefix("/") ? String(self.name.dropFirst()) : self.name
        let short = noTrunc ? id : Format.shortID(id)
        return [
            ("ID", short),
            ("Name", name),
            ("CPUPerc", String(format: "%.2f%%", cpuPercent)),
            ("MemUsage", "\(Format.size(Int64(clamping: memory_stats.usage))) / \(Format.size(Int64(clamping: limit)))"),
            ("MemPerc", String(format: "%.2f%%", memPercent)),
            ("NetIO", "\(Format.size(Int64(clamping: rx))) / \(Format.size(Int64(clamping: tx)))"),
            ("BlockIO", "0B / 0B"),
            ("PIDs", "\(pids_stats?.current ?? 0)"),
            ("Container", short),
        ]
    }
}

private struct ContainerPruneResponse: Decodable {
    var ContainersDeleted: [String]?
    var SpaceReclaimed: Int64?
}
