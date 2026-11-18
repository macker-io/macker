import ArgumentParser
import ContainerEngine
import Darwin
import Foundation
import os

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

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Update configuration of one or more containers.")

    @Option(name: .customLong("blkio-weight"), help: "Block IO (relative weight), between 10 and 1000.")
    var blkioWeight: Int?

    @Option(name: .customLong("cpu-period"), help: "Limit CPU CFS period.")
    var cpuPeriod: Int?

    @Option(name: .customLong("cpu-quota"), help: "Limit CPU CFS quota.")
    var cpuQuota: Int?

    @Option(name: .customLong("cpu-rt-period"), help: "Limit the CPU real-time period in microseconds.")
    var cpuRtPeriod: Int?

    @Option(name: .customLong("cpu-rt-runtime"), help: "Limit the CPU real-time runtime in microseconds.")
    var cpuRtRuntime: Int?

    @Option(name: [.customShort("c"), .customLong("cpu-shares")], help: "CPU shares (relative weight).")
    var cpuShares: Int?

    @Option(help: "Number of CPUs.")
    var cpus: Double?

    @Option(name: .customLong("cpuset-cpus"), help: "CPUs in which to allow execution (0-3, 0,1).")
    var cpusetCpus: String?

    @Option(name: .customLong("cpuset-mems"), help: "MEMs in which to allow execution (0-3, 0,1).")
    var cpusetMems: String?

    @Option(name: [.customShort("m"), .long], help: "Memory limit.")
    var memory: String?

    @Option(name: .customLong("memory-reservation"), help: "Memory soft limit.")
    var memoryReservation: String?

    @Option(name: .customLong("memory-swap"), help: "Swap limit equal to memory plus swap: '-1' for unlimited swap.")
    var memorySwap: String?

    @Option(name: .customLong("pids-limit"), help: "Tune container pids limit (set -1 for unlimited).")
    var pidsLimit: Int?

    @Option(help: "Restart policy to apply when a container exits.")
    var restart: String?

    @Option(name: .customLong("cpu-count"), help: "Windows: CPU count.")
    var cpuCount: Int?

    @Option(name: .customLong("cpu-percent"), help: "Windows: CPU percent.")
    var cpuPercent: Int?

    @Option(name: .customLong("io-maxbandwidth"), help: "Windows: maximum IO bandwidth limit.")
    var ioMaxBandwidth: String?

    @Option(name: .customLong("io-maxiops"), help: "Windows: maximum IOps limit.")
    var ioMaxIOps: Int?

    @Argument var containers: [String]

    func run() throws {
        let body = try encodedBody()
        for id in containers {
            let response = try DaemonAPI.decode(
                UpdateResponse.self,
                from: DaemonAPI.post("/containers/\(DaemonAPI.path(id))/update", body: body, timeoutSeconds: 30)
            )
            for warning in response.Warnings ?? [] {
                fputs("\(warning)\n", stderr)
            }
            print(id)
        }
    }

    private func encodedBody() throws -> Data {
        var body: [String: Any] = [:]
        if let memory { body["Memory"] = try DaemonAPI.parseBytes(memory) }
        if let cpus { body["NanoCpus"] = Int64((cpus * 1_000_000_000).rounded()) }
        if let restart {
            let policy = try EngineRestartPolicy.parse(restart)
            body["RestartPolicy"] = [
                "Name": policy.name,
                "MaximumRetryCount": policy.maximumRetryCount,
            ]
        }
        if let cpuShares { body["CpuShares"] = cpuShares }
        if let cpuPeriod { body["CpuPeriod"] = cpuPeriod }
        if let cpuQuota { body["CpuQuota"] = cpuQuota }
        if let cpuRtPeriod { body["CpuRealtimePeriod"] = cpuRtPeriod }
        if let cpuRtRuntime { body["CpuRealtimeRuntime"] = cpuRtRuntime }
        if let cpusetCpus { body["CpusetCpus"] = cpusetCpus }
        if let cpusetMems { body["CpusetMems"] = cpusetMems }
        if let memoryReservation { body["MemoryReservation"] = try DaemonAPI.parseBytes(memoryReservation) }
        if let memorySwap {
            body["MemorySwap"] = memorySwap == "-1" ? -1 : try DaemonAPI.parseBytes(memorySwap)
        }
        if let blkioWeight { body["BlkioWeight"] = blkioWeight }
        if let pidsLimit { body["PidsLimit"] = pidsLimit }
        if let cpuCount { body["CpuCount"] = cpuCount }
        if let cpuPercent { body["CpuPercent"] = cpuPercent }
        if let ioMaxBandwidth { body["IOMaximumBandwidth"] = try DaemonAPI.parseBytes(ioMaxBandwidth) }
        if let ioMaxIOps { body["IOMaximumIOps"] = ioMaxIOps }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private struct UpdateResponse: Decodable {
        var Warnings: [String]?
    }
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
        let result = try DaemonAPI.decode(
            ContainerPruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath("/containers/prune", filters: filter))
        )
        if let ids = result.containersDeleted, !ids.isEmpty {
            print("Deleted Containers:")
            for id in ids {
                print(id)
            }
        }
        print("Total reclaimed space: \(Format.size(result.spaceReclaimed ?? 0))")
    }
}

struct ContainerGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "Manage containers.",
        subcommands: [
            ContainerLs.self, Run.self, Create.self, Start.self, Stop.self, Restart.self, Update.self, Kill.self,
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

enum ContainerAttach {
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

struct ContainerSummary: Decodable {
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

struct AttachInspect: Decodable {
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


struct WaitResponse: Decodable {
    var StatusCode: Int
}

