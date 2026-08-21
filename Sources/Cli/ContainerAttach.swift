import ArgumentParser
import ContainerEngine
import Darwin
import Foundation
import os

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

