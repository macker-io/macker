import ArgumentParser
import Foundation

struct VolumeGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume",
        abstract: "Manage volumes.",
        subcommands: [VolumeLs.self, VolumeCreate.self, VolumeInspect.self, VolumeRm.self, VolumePrune.self]
    )
}

struct VolumeLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List volumes.")

    func run() throws {
        let list = try DaemonAPI.decode(VolumeList.self, from: DaemonAPI.get("/volumes"))
        let rows = (list.Volumes ?? []).map { [$0.Driver, $0.Name] }
        Table.print(headers: ["DRIVER", "VOLUME NAME"], rows: rows)
    }
}

struct VolumeCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a volume.")
    @Option var driver: String = "local"
    @Argument var name: String?

    func run() throws {
        let body = VolumeCreateBody(Name: name, Driver: driver)
        try DaemonAPI.printJSON(try DaemonAPI.requireOK(DaemonAPI.post("/volumes/create", body: JSONEncoder().encode(body))).body)
    }
}

struct VolumeInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more volumes.")
    @Argument var volumes: [String]
    func run() throws { try Inspect.inspect(volumes, prefer: .volume) }
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
    @Flag(name: .shortAndLong) var force = false

    func run() throws {
        guard Prompt.confirm("This will remove all local volumes not used by at least one container.", force: force) else {
            return
        }
        try DaemonAPI.printJSON(try DaemonAPI.requireOK(DaemonAPI.post("/volumes/prune")).body)
    }
}

private struct VolumeList: Decodable {
    var Volumes: [VolumeItem]?
}

private struct VolumeItem: Decodable {
    var Name: String
    var Driver: String
}

private struct VolumeCreateBody: Encodable {
    var Name: String?
    var Driver: String
}
