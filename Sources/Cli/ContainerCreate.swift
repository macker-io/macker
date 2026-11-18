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

    struct EncodedRequest {
        var path: String
        var body: Data
    }

    static func submit(_ options: ContainerCreateOptions, autoRemove: Bool) throws -> String {
        let encoded = try encodeRequest(options, autoRemove: autoRemove)
        try Self.pullIfNeeded(options)
        let created: CreateResponse
        if let existing = try Self.create(path: encoded.path, payload: encoded.body) {
            created = existing
        } else {
            if (options.pull ?? "missing") == "never" {
                throw CLIError.http("No such image: \(options.image)")
            }
            let (name, tag) = DaemonAPI.splitReference(options.image)
            print("Unable to find image '\(name):\(tag)' locally")
            try Pull.submit(options.image, platform: options.platform, quiet: options.quiet)
            guard let retry = try Self.create(path: encoded.path, payload: encoded.body) else {
                throw CLIError.http("No such image: \(options.image)")
            }
            created = retry
        }
        for warning in created.Warnings ?? [] {
            fputs("WARNING: \(warning)\n", stderr)
        }
        return created.Id
    }

    static func encodeRequest(_ options: ContainerCreateOptions, autoRemove: Bool) throws -> EncodedRequest {
        try rejectRestartWithAutoRemove(restart: options.restart, autoRemove: autoRemove)
        try validatePull(options.pull)
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
        var path = "/containers/create"
        if let name = options.name, !name.isEmpty {
            path += "?name=\(DaemonAPI.query(name))"
        }
        return EncodedRequest(path: path, body: try Self.attachUnsupported(JSONEncoder().encode(body), options))
    }

    /// Fields the engine records only as warnings. Sending them keeps `macker run` and the Engine API on one path.
    private static func attachUnsupported(_ data: Data, _ options: ContainerCreateOptions) throws -> Data {
        var root = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        var host = (root["HostConfig"] as? [String: Any]) ?? [:]
        if !options.capAdd.isEmpty { host["CapAdd"] = options.capAdd }
        if !options.capDrop.isEmpty { host["CapDrop"] = options.capDrop }
        if !options.securityOpt.isEmpty { host["SecurityOpt"] = options.securityOpt }
        if !options.sysctl.isEmpty {
            var sysctls: [String: String] = [:]
            for item in options.sysctl {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = parts.first, !key.isEmpty else { continue }
                sysctls[key] = parts.count == 2 ? parts[1] : ""
            }
            if !sysctls.isEmpty { host["Sysctls"] = sysctls }
        }
        if !options.device.isEmpty { host["Devices"] = options.device }
        if let gpus = options.gpus, !gpus.isEmpty { host["DeviceRequests"] = [gpus] }
        if !options.deviceCgroupRule.isEmpty { host["DeviceCgroupRules"] = options.deviceCgroupRule }
        if !options.ulimit.isEmpty { host["Ulimits"] = options.ulimit }
        if let shm = options.shmSize { host["ShmSize"] = try DaemonAPI.parseBytes(shm) }
        if let logDriver = options.logDriver, !logDriver.isEmpty, logDriver != "json-file" {
            var config: [String: String] = [:]
            for item in options.logOpt {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = parts.first, !key.isEmpty else { continue }
                config[key] = parts.count == 2 ? parts[1] : ""
            }
            host["LogConfig"] = ["Type": logDriver, "Config": config]
        }
        if options.`init` { host["Init"] = true }
        if let pid = options.pid, !pid.isEmpty { host["PidMode"] = pid }
        if let ipc = options.ipc, !ipc.isEmpty { host["IpcMode"] = ipc }
        if let uts = options.uts, !uts.isEmpty { host["UTSMode"] = uts }
        if let cgroupns = options.cgroupns, !cgroupns.isEmpty { host["CgroupnsMode"] = cgroupns }
        if let userns = options.userns, !userns.isEmpty { host["UsernsMode"] = userns }
        if let isolation = options.isolation, !isolation.isEmpty { host["Isolation"] = isolation }
        if let parent = options.cgroupParent, !parent.isEmpty { host["CgroupParent"] = parent }
        if let shares = options.cpuShares { host["CpuShares"] = shares }
        if let period = options.cpuPeriod { host["CpuPeriod"] = period }
        if let quota = options.cpuQuota { host["CpuQuota"] = quota }
        if let cpus = options.cpusetCpus, !cpus.isEmpty { host["CpusetCpus"] = cpus }
        if let mems = options.cpusetMems, !mems.isEmpty { host["CpusetMems"] = mems }
        if let reservation = options.memoryReservation { host["MemoryReservation"] = try DaemonAPI.parseBytes(reservation) }
        if let swap = options.memorySwap {
            host["MemorySwap"] = swap == "-1" ? -1 : try DaemonAPI.parseBytes(swap)
        }
        if let swappiness = options.memorySwappiness { host["MemorySwappiness"] = swappiness }
        if let pids = options.pidsLimit { host["PidsLimit"] = pids }
        if !host.isEmpty { root["HostConfig"] = host }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private static func validatePull(_ pull: String?) throws {
        switch pull ?? "missing" {
        case "always", "missing", "never":
            return
        default:
            throw CLIError.io("invalid --pull value \(pull ?? "")")
        }
    }

    private static func pullIfNeeded(_ options: ContainerCreateOptions) throws {
        if (options.pull ?? "missing") == "always" {
            try Pull.submit(options.image, platform: options.platform, quiet: options.quiet)
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
        if let ip6 = options.ip6, specs[0].ipv6 == nil {
            specs[0].ipv6 = ip6
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
        if endpoints.count == 1, specs[0].name == "default", options.ip == nil, options.ip6 == nil, options.networkAlias.isEmpty, options.link.isEmpty, options.macAddress == nil, options.linkLocalIP.isEmpty {
            return (mode, [:])
        }
        return (mode, endpoints)
    }

    private static func endpointConfig(_ spec: EngineNetworkAttachSpec) throws -> CreateBody.EndpointConfig {
        let request = try spec.asRequest()
        let ipam: CreateBody.IPAMConfig?
        if request.ipv4 != nil || request.ipv6 != nil || !spec.linkLocalIPs.isEmpty {
            ipam = .init(
                IPv4Address: request.ipv4,
                IPv6Address: request.ipv6,
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
