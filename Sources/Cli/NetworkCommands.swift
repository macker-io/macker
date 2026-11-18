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

    @Option(name: [.customShort("f"), .long], help: "Filter output (e.g. 'driver=bridge', 'label=key=value').")
    var filter: [String] = []

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Flag(name: [.customShort("q"), .long], help: "Only display network IDs.")
    var quiet = false

    @Flag(name: .customLong("no-trunc"), help: "Do not truncate output.")
    var noTrunc = false

    func run() throws {
        var path = "/networks"
        if !filter.isEmpty {
            path += "?filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(filter)))"
        }
        let networks = try DaemonAPI.decode([NetworkItem].self, from: DaemonAPI.get(path))

        if quiet {
            for network in networks {
                print(noTrunc ? network.Id : Format.shortID(network.Id))
            }
            return
        }

        let rows: [[(String, String)]] = networks.map { network in
            let labels = (network.Labels ?? [:]).keys.sorted().map { key in
                "\(key)=\(network.Labels?[key] ?? "")"
            }.joined(separator: ",")
            return [
                ("ID", noTrunc ? network.Id : Format.shortID(network.Id)),
                ("Name", network.Name),
                ("Driver", network.Driver),
                ("Scope", network.Scope),
                ("IPv6", network.EnableIPv6 ? "true" : "false"),
                ("Internal", network.Internal ? "true" : "false"),
                ("Labels", labels),
                ("CreatedAt", network.Created),
            ]
        }
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, rows: rows)
            return
        }
        Table.print(headers: ["NETWORK ID", "NAME", "DRIVER", "SCOPE"], rows: rows.map {
            [$0[0].1, $0[1].1, $0[2].1, $0[3].1]
        })
    }
}

struct NetworkCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a network.")

    @Option(name: [.customShort("d"), .long], help: "Driver to manage the network (only bridge is supported).")
    var driver: String = "bridge"

    @Option(help: "Subnet in CIDR format.")
    var subnet: [String] = []

    @Option(help: "IPv4 gateway for the subnet.")
    var gateway: [String] = []

    @Option(name: .customLong("ip-range"), help: "Allocate container IPs from a sub-range.")
    var ipRange: [String] = []

    @Option(name: .customLong("aux-address"), help: "Auxiliary IPv4 addresses used by the network (name=ip).")
    var auxAddress: [String] = []

    @Option(name: [.customShort("o"), .customLong("opt")], help: "Set driver-specific options (key=value).")
    var opt: [String] = []

    @Option(name: .customLong("ipv4"), help: "Enable or disable IPv4 address assignment.")
    var ipv4: Bool = true

    @Option(name: .customLong("ipv6"), help: "Enable or disable IPv6 address assignment.")
    var ipv6: Bool = false

    @Option(name: .customLong("ipam-driver"), help: "IP Address Management driver.")
    var ipamDriver: String = "default"

    @Option(name: .customLong("ipam-opt"), help: "Set IPAM driver-specific options (key=value).")
    var ipamOpt: [String] = []

    @Flag(help: "Restrict external access to the network.")
    var `internal` = false

    @Option(name: .customLong("label"), help: "Set metadata on a network.")
    var label: [String] = []

    @Argument var name: String?

    func run() throws {
        let created = try DaemonAPI.decode(
            NetworkCreateResponse.self,
            from: DaemonAPI.post("/networks/create", body: try encodedBody())
        )
        print(created.Id)
    }

    func encodedBody() throws -> Data {
        let subnet4 = try Self.singleValue(subnet.filter { !$0.contains(":") }, what: "IPv4 subnet")
        let subnet6 = try Self.singleValue(subnet.filter { $0.contains(":") }, what: "IPv6 subnet")
        let gateway4 = try Self.singleValue(gateway.filter { !$0.contains(":") }, what: "IPv4 gateway")
        let gateway6 = try Self.singleValue(gateway.filter { $0.contains(":") }, what: "IPv6 gateway")
        let ipRange4 = try Self.singleValue(ipRange.filter { !$0.contains(":") }, what: "IPv4 ip-range")
        var configs: [NetworkCreateBody.IPAM.Config] = []
        if subnet4 != nil || gateway4 != nil || ipRange4 != nil || !auxAddress.isEmpty {
            configs.append(
                .init(
                    Subnet: subnet4,
                    IPRange: ipRange4,
                    Gateway: gateway4,
                    AuxiliaryAddresses: NetworkKeyValues.map(auxAddress)
                )
            )
        }
        if subnet6 != nil || gateway6 != nil {
            configs.append(
                .init(
                    Subnet: subnet6,
                    IPRange: nil,
                    Gateway: gateway6,
                    AuxiliaryAddresses: nil
                )
            )
        }
        var ipam: NetworkCreateBody.IPAM?
        if !configs.isEmpty || ipamDriver != "default" || !ipamOpt.isEmpty {
            ipam = .init(
                Driver: ipamDriver,
                Config: configs,
                Options: NetworkKeyValues.map(ipamOpt)
            )
        }
        let body = NetworkCreateBody(
            Name: name,
            Driver: driver,
            Internal: `internal`,
            EnableIPv4: ipv4,
            EnableIPv6: ipv6,
            Labels: NetworkKeyValues.map(label),
            Options: NetworkKeyValues.map(opt),
            IPAM: ipam
        )
        return try JSONEncoder().encode(body)
    }

    static func singleValue(_ values: [String], what: String) throws -> String? {
        guard values.count <= 1 else {
            throw CLIError.io("only one \(what) is supported")
        }
        return values.first
    }
}

struct NetworkInspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Display detailed information on one or more networks."
    )

    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Flag(name: [.customShort("v"), .long], help: "Verbose output for debugging.")
    var verbose = false

    @Argument var networks: [String]
    func run() throws { try Inspect.inspect(networks, prefer: .network, format: format, verbose: verbose) }
}

struct NetworkRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more networks.")

    @Flag(name: .shortAndLong, help: "Do not error if the network does not exist.")
    var force = false

    @Argument var networks: [String]

    func run() throws {
        for name in networks {
            let response = try DaemonAPI.delete("/networks/\(DaemonAPI.path(name))")
            if force, response.statusCode == 404 {
                continue
            }
            try DaemonAPI.requireOK(response)
            print(name)
        }
    }
}

struct NetworkConnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect a container to a network."
    )

    @Option(help: "Add a network-scoped alias for the container.")
    var alias: [String] = []

    @Option(help: "IPv4 address to assign to the container.")
    var ip: String?

    @Option(help: "IPv6 address to assign to the container.")
    var ip6: String?

    @Option(help: "Add a link to another container (name:alias).")
    var link: [String] = []

    @Option(name: .customLong("link-local-ip"), help: "Add a link-local address for the container.")
    var linkLocalIP: [String] = []

    @Option(name: .customLong("driver-opt"), help: "Set driver-specific options (key=value).")
    var driverOpt: [String] = []

    @Option(name: .customLong("gw-priority"), help: "Gateway priority for this endpoint.")
    var gwPriority: Int?

    @Argument var network: String
    @Argument var container: String

    func run() throws {
        var aliases = alias
        for item in link {
            let value = item.split(separator: ":").last.map(String.init) ?? item
            if !value.isEmpty, !aliases.contains(value) {
                aliases.append(value)
            }
        }
        var ipam: NetworkConnectBody.EndpointConfig.IPAMConfig?
        if ip != nil || ip6 != nil || !linkLocalIP.isEmpty {
            ipam = .init(IPv4Address: ip, IPv6Address: ip6, LinkLocalIPs: linkLocalIP.isEmpty ? nil : linkLocalIP)
        }
        let endpoint: NetworkConnectBody.EndpointConfig? =
            (aliases.isEmpty && ipam == nil && driverOpt.isEmpty && gwPriority == nil)
            ? nil
            : .init(
                Aliases: aliases.isEmpty ? nil : aliases,
                Links: link.isEmpty ? nil : link,
                IPAMConfig: ipam,
                DriverOpts: NetworkKeyValues.map(driverOpt),
                GwPriority: gwPriority
            )
        let body = NetworkConnectBody(Container: container, EndpointConfig: endpoint)
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

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var force = false

    @Option(help: "Filter what to prune (e.g. 'until=24h', 'label=key=value').")
    var filter: [String] = []

    func run() throws {
        guard Prompt.confirm("This will remove all custom networks not used by at least one container.", force: force)
        else {
            return
        }
        let result = try DaemonAPI.decode(
            NetworkPruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath("/networks/prune", filters: filter))
        )
        if let names = result.networksDeleted, !names.isEmpty {
            print("Deleted Networks:")
            for name in names {
                print(name)
            }
        }
    }
}

private enum NetworkKeyValues {
    static func map(_ items: [String]) -> [String: String]? {
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

private struct NetworkItem: Decodable {
    var Id: String
    var Name: String
    var Driver: String
    var Scope: String
    var Created: String
    var Internal: Bool
    var EnableIPv6: Bool
    var Labels: [String: String]?
}

private struct NetworkCreateBody: Encodable {
    var Name: String?
    var Driver: String
    var Internal: Bool
    var EnableIPv4: Bool
    var EnableIPv6: Bool
    var Labels: [String: String]?
    var Options: [String: String]?
    var IPAM: IPAM?

    struct IPAM: Encodable {
        var Driver: String?
        var Config: [Config]
        var Options: [String: String]?

        struct Config: Encodable {
            var Subnet: String?
            var IPRange: String?
            var Gateway: String?
            var AuxiliaryAddresses: [String: String]?
        }
    }
}

private struct NetworkCreateResponse: Decodable {
    var Id: String
}

private struct NetworkConnectBody: Encodable {
    var Container: String
    var EndpointConfig: EndpointConfig?

    struct EndpointConfig: Encodable {
        var Aliases: [String]?
        var Links: [String]?
        var IPAMConfig: IPAMConfig?
        var DriverOpts: [String: String]?
        var GwPriority: Int?

        struct IPAMConfig: Encodable {
            var IPv4Address: String?
            var IPv6Address: String?
            var LinkLocalIPs: [String]?
        }
    }
}

private struct NetworkDisconnectBody: Encodable {
    var Container: String
    var Force: Bool
}

