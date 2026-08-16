import ArgumentParser
import Foundation

struct NetworkGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Manage networks.",
        subcommands: [
            NetworkLs.self, NetworkCreate.self, NetworkInspect.self, NetworkRm.self,
            NetworkConnect.self, NetworkDisconnect.self, NetworkPrune.self,
        ]
    )
}

struct NetworkLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List networks.")

    func run() throws {
        let networks = try DaemonAPI.decode([NetworkItem].self, from: DaemonAPI.get("/networks"))
        let rows = networks.map {
            [Format.shortID($0.Id), $0.Name, $0.Driver, $0.Scope]
        }
        Table.print(headers: ["NETWORK ID", "NAME", "DRIVER", "SCOPE"], rows: rows)
    }
}

struct NetworkCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a network.")

    @Option var driver: String = "bridge"
    @Option var subnet: String?
    @Option var gateway: String?
    @Flag var `internal` = false
    @Option(name: .customLong("label"), help: "Set metadata on a network.")
    var label: [String] = []
    @Argument var name: String?

    func run() throws {
        var labels: [String: String] = [:]
        for item in label {
            if let eq = item.firstIndex(of: "=") {
                labels[String(item[..<eq])] = String(item[item.index(after: eq)...])
            } else {
                labels[item] = ""
            }
        }
        var ipam: NetworkCreateBody.IPAM?
        if subnet != nil || gateway != nil {
            ipam = .init(Config: [.init(Subnet: subnet, Gateway: gateway)])
        }
        let body = NetworkCreateBody(
            Name: name,
            Driver: driver,
            Internal: `internal`,
            Labels: labels.isEmpty ? nil : labels,
            IPAM: ipam
        )
        let created = try DaemonAPI.decode(
            NetworkCreateResponse.self,
            from: DaemonAPI.post("/networks/create", body: JSONEncoder().encode(body))
        )
        print(created.Id)
    }
}

struct NetworkInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Display detailed information on one or more networks."
    )
    @Argument var networks: [String]
    func run() throws { try Inspect.inspect(networks, prefer: .network) }
}

struct NetworkRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more networks.")
    @Argument var networks: [String]

    func run() throws {
        for name in networks {
            try DaemonAPI.requireOK(DaemonAPI.delete("/networks/\(DaemonAPI.path(name))"))
            print(name)
        }
    }
}

struct NetworkConnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect a container to a network."
    )
    @Argument var network: String
    @Argument var container: String

    func run() throws {
        let body = NetworkConnectBody(Container: container)
        try DaemonAPI.requireOK(
            DaemonAPI.post("/networks/\(DaemonAPI.path(network))/connect", body: JSONEncoder().encode(body))
        )
    }
}

struct NetworkDisconnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Disconnect a container from a network."
    )
    @Flag(name: .shortAndLong) var force = false
    @Argument var network: String
    @Argument var container: String

    func run() throws {
        let body = NetworkDisconnectBody(Container: container, Force: force)
        try DaemonAPI.requireOK(
            DaemonAPI.post("/networks/\(DaemonAPI.path(network))/disconnect", body: JSONEncoder().encode(body))
        )
    }
}

struct NetworkPrune: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove all unused networks.")
    @Flag(name: .shortAndLong) var force = false

    func run() throws {
        guard Prompt.confirm("This will remove all custom networks not used by at least one container.", force: force) else {
            return
        }
        try DaemonAPI.printJSON(try DaemonAPI.requireOK(DaemonAPI.post("/networks/prune")).body)
    }
}

private struct NetworkItem: Decodable {
    var Id: String
    var Name: String
    var Driver: String
    var Scope: String
}

private struct NetworkCreateBody: Encodable {
    var Name: String?
    var Driver: String
    var Internal: Bool
    var Labels: [String: String]?
    var IPAM: IPAM?

    struct IPAM: Encodable {
        var Config: [Config]
        struct Config: Encodable {
            var Subnet: String?
            var Gateway: String?
        }
    }
}

private struct NetworkCreateResponse: Decodable {
    var Id: String
}

private struct NetworkConnectBody: Encodable {
    var Container: String
}

private struct NetworkDisconnectBody: Encodable {
    var Container: String
    var Force: Bool
}
