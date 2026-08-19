import ArgumentParser
import ContainerEngine
import Darwin
import Foundation
import os

struct ContainerCreateOptions: ParsableArguments {
    @Option(help: "Assign a name to the container.")
    var name: String?

    @Option(name: .shortAndLong, help: "Set environment variables.")
    var env: [String] = []

    @Option(name: .shortAndLong, help: "Working directory inside the container.")
    var workdir: String?

    @Option(help: "Overwrite the default ENTRYPOINT.")
    var entrypoint: String?

    @Flag(name: .shortAndLong, help: "Allocate a pseudo-TTY.")
    var tty = false

    @Flag(name: [.customShort("i"), .long], help: "Keep STDIN open.")
    var interactive = false

    @Option(help: "Memory limit, e.g. 128m.")
    var memory: String?

    @Option(name: .shortAndLong, help: "Bind mount a volume.")
    var volume: [String] = []

    @Option(name: [.customShort("p"), .customLong("publish")], help: "Publish a container's port(s) to the host.")
    var publish: [String] = []

    @Option(name: .customLong("network"), help: "Connect a container to a network (bridge, host, none, or a custom name).")
    var network: String?

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

    @OptionGroup var options: ContainerCreateOptions

    func run() throws {
        let id = try Create.submit(options, autoRemove: rm && detach)
        if detach {
            try DaemonAPI.requireOK(DaemonAPI.post("/containers/\(DaemonAPI.path(id))/start", timeoutSeconds: 300))
            print(id)
            return
        }
        try ContainerAttach.attachAndStart(
            id: id,
            interactive: options.interactive,
            tty: options.tty,
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
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new container.")

    @OptionGroup var options: ContainerCreateOptions

    func run() throws {
        print(try Self.submit(options, autoRemove: false))
    }

    static func submit(_ options: ContainerCreateOptions, autoRemove: Bool) throws -> String {
        var host = CreateBody.HostConfig(
            AutoRemove: autoRemove ? true : nil,
            Memory: nil,
            Binds: options.volume.isEmpty ? nil : options.volume,
            NetworkMode: options.network,
            PortBindings: try Self.portBindings(options.publish)
        )
        if let memory = options.memory {
            host.Memory = try DaemonAPI.parseBytes(memory)
        }
        let body = CreateBody(
            Image: options.image,
            Cmd: options.command.isEmpty ? nil : options.command,
            Env: options.env.isEmpty ? nil : options.env,
            Entrypoint: options.entrypoint.map { [$0] },
            WorkingDir: options.workdir,
            Tty: options.tty ? true : nil,
            OpenStdin: options.interactive ? true : nil,
            HostConfig: host
        )
        var path = "/containers/create"
        if let name = options.name, !name.isEmpty {
            path += "?name=\(DaemonAPI.query(name))"
        }
        let payload = try JSONEncoder().encode(body)
        let created: CreateResponse
        if let existing = try Self.create(path: path, payload: payload) {
            created = existing
        } else {
            let (name, tag) = DaemonAPI.splitReference(options.image)
            print("Unable to find image '\(name):\(tag)' locally")
            try Pull.submit(options.image)
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
                interactive: interactive,
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
    var time: Int = 10

    @Option(help: "Signal to send to the container.")
    var signal: String?

    @Argument var containers: [String]
    func run() throws {
        var query = "t=\(time)"
        if let signal { query += "&signal=\(DaemonAPI.query(signal))" }
        try ContainerAction.post("stop", containers, query: query, timeoutSeconds: time + 30)
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
        interactive: Bool,
        tty: Bool,
        detachKeys: String? = nil,
        deleteOnFailure: Bool = false
    ) throws {
        let query = interactive
            ? "stream=1&stdout=1&stderr=1&stdin=1"
            : "stream=1&stdout=1&stderr=1"
        let keys: [UInt8]?
        if interactive {
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
                    stdin: interactive,
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
        let interrupt = ProcessSignalProxy(enabled: !tty, signals: [(SIGINT, "SIGINT")]) { _ in
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
    var Image: String
    var Cmd: [String]?
    var Env: [String]?
    var Entrypoint: [String]?
    var WorkingDir: String?
    var Tty: Bool?
    var OpenStdin: Bool?
    var HostConfig: HostConfig?

    struct HostConfig: Encodable {
        var AutoRemove: Bool?
        var Memory: Int64?
        var Binds: [String]?
        var NetworkMode: String?
        var PortBindings: [String: [PortBinding]]?
    }

    struct PortBinding: Encodable {
        var HostIp: String
        var HostPort: String
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
