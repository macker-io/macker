import ArgumentParser
import Foundation

struct VolumeGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Manage volumes.",
        subcommands: [VolumeLs.self, VolumeList.self, VolumeCreate.self, VolumeInspect.self, VolumeRm.self, VolumePrune.self]
    )
}

struct VolumeListOptions: ParsableArguments {
    @Option(name: [.customShort("f"), .long], help: "Filter output (e.g. 'dangling=true', 'label=key=value').")
    var filter: [String] = []

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Flag(name: [.customShort("q"), .long], help: "Only display volume names.")
    var quiet = false
}

struct VolumeLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List volumes.")

    @OptionGroup var options: VolumeListOptions

    func run() throws {
        try Self.list(options)
    }

    static func list(_ options: VolumeListOptions) throws {
        let filter = options.filter
        let format = options.format
        let quiet = options.quiet
        var path = "/volumes"
        if !filter.isEmpty {
            path += "?filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(filter)))"
        }
        let list = try DaemonAPI.decode(VolumeListResponse.self, from: DaemonAPI.get(path))
        let volumes = list.Volumes ?? []

        if quiet {
            for volume in volumes {
                print(volume.Name)
            }
            return
        }

        let rows: [[(String, String)]] = volumes.map { volume in
            let labels = (volume.Labels ?? [:]).keys.sorted().map { key in
                "\(key)=\(volume.Labels?[key] ?? "")"
            }.joined(separator: ",")
            let size = volume.UsageData.map { Format.size($0.Size) } ?? ""
            return [
                ("Driver", volume.Driver),
                ("Name", volume.Name),
                ("Scope", volume.Scope ?? "local"),
                ("Mountpoint", volume.Mountpoint ?? ""),
                ("Labels", labels),
                ("CreatedAt", volume.CreatedAt ?? ""),
                ("Size", size),
            ]
        }
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, rows: rows)
            return
        }
        Table.print(headers: ["DRIVER", "VOLUME NAME"], rows: rows.map { [$0[0].1, $0[1].1] })
    }
}

struct VolumeList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List volumes.", shouldDisplay: false)
    @OptionGroup var options: VolumeListOptions
    func run() throws { try VolumeLs.list(options) }
}

struct VolumeCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a volume.")

    @Option(name: [.customShort("d"), .long], help: "Volume driver (only local is supported).")
    var driver: String = "local"

    @Option(name: .customLong("label"), help: "Set metadata on a volume (key=value).")
    var label: [String] = []

    @Option(name: [.customShort("o"), .customLong("opt")], help: "Set driver-specific options (key=value).")
    var opt: [String] = []

    @Argument var name: String?

    func run() throws {
        let body = VolumeCreateBody(
            Name: name,
            Driver: driver,
            Labels: Self.keyValues(label),
            DriverOpts: Self.keyValues(opt)
        )
        try DaemonAPI.printJSON(try DaemonAPI.requireOK(DaemonAPI.post("/volumes/create", body: JSONEncoder().encode(body))).body)
    }

    private static func keyValues(_ items: [String]) -> [String: String]? {
        guard !items.isEmpty else { return nil }
        var map: [String: String] = [:]
        for item in items {
            if let eq = item.firstIndex(of: "=") {
                map[String(item[..<eq])] = String(item[item.index(after: eq)...])
            } else {
                map[item] = ""
            }
        }
        return map
    }
}

struct VolumeInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Display detailed information on one or more volumes."
    )

    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Argument var volumes: [String]

    func run() throws { try Inspect.inspect(volumes, prefer: .volume, format: format) }
}

struct VolumeRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more volumes.")
    @Flag(name: .shortAndLong) var force = false
    @Argument var volumes: [String]

    func run() throws {
        for name in volumes {
            var path = "/volumes/\(DaemonAPI.path(name))"
            if force { path += "?force=1" }
            try DaemonAPI.requireOK(DaemonAPI.delete(path))
            print(name)
        }
    }
}

struct VolumePrune: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove all unused local volumes.")

    @Flag(name: [.customShort("a"), .long], help: "Remove all unused volumes, not just anonymous ones.")
    var all = false

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var force = false

    @Option(help: "Filter what to prune (e.g. 'label=key=value').")
    var filter: [String] = []

    func run() throws {
        let warning = all
            ? "This will remove all unused local volumes, including named volumes."
            : "This will remove all unused anonymous local volumes."
        guard Prompt.confirm(warning, force: force) else { return }
        let filters = all ? filter + ["all=true"] : filter
        let result = try DaemonAPI.decode(
            VolumePruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath("/volumes/prune", filters: filters), timeoutSeconds: 120)
        )
        if let names = result.volumesDeleted, !names.isEmpty {
            print("Deleted Volumes:")
            for name in names {
                print(name)
            }
        }
        print("Total reclaimed space: \(Format.size(result.spaceReclaimed ?? 0))")
    }
}

private struct VolumeListResponse: Decodable {
    var Volumes: [VolumeItem]?
}

private struct VolumeItem: Decodable {
    var Name: String
    var Driver: String
    var Scope: String?
    var Mountpoint: String?
    var Labels: [String: String]?
    var CreatedAt: String?
    var UsageData: Usage?

    struct Usage: Decodable {
        var Size: Int64
        var RefCount: Int64
    }
}

private struct VolumeCreateBody: Encodable {
    var Name: String?
    var Driver: String
    var Labels: [String: String]?
    var DriverOpts: [String: String]?
}

