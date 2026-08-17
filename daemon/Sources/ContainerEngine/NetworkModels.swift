import Foundation

public struct EngineNetwork: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var driver: String
    public var scope: String
    public var created: Date
    public var labels: [String: String]
    public var subnet: String
    public var gateway: String
    public var internalNetwork: Bool
    public var builtin: Bool
}

public struct EngineEndpoint: Sendable, Codable, Equatable {
    public var networkID: String
    public var networkName: String
    public var ipv4Address: String
    public var ipv4Prefix: Int
    public var gateway: String
    public var macAddress: String
    public var aliases: [String]
}

public struct EngineEndpointRequest: Sendable {
    public var network: String
    public var aliases: [String]

    public init(network: String, aliases: [String] = []) {
        self.network = network
        self.aliases = aliases
    }
}

public struct EngineNetworkCreateSpec: Sendable {
    public var name: String?
    public var driver: String
    public var labels: [String: String]
    public var subnet: String?
    public var gateway: String?
    public var internalNetwork: Bool

    public init(
        name: String? = nil,
        driver: String = "bridge",
        labels: [String: String] = [:],
        subnet: String? = nil,
        gateway: String? = nil,
        internalNetwork: Bool = false
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.subnet = subnet
        self.gateway = gateway
        self.internalNetwork = internalNetwork
    }
}

public struct EngineNetworkContainer: Sendable {
    public var id: String
    public var name: String
    public var endpointID: String
    public var macAddress: String
    public var ipv4Address: String
}

public struct EngineNetworkInspect: Sendable {
    public var network: EngineNetwork
    public var containers: [EngineNetworkContainer]
}

public struct EngineNetworkConnectSpec: Sendable {
    public var container: String
    public var aliases: [String]

    public init(container: String, aliases: [String] = []) {
        self.container = container
        self.aliases = aliases
    }
}

/// Guest virtio-net slot for a running MicroVM. VZ cannot hot-plug NICs, so a
/// running connect can only reuse a slot that was attached at boot.
struct GuestNic: Sendable {
    var interfaceName: String
    var networkID: String
    var ipv4Address: String
    var ipv4Prefix: Int
    var gateway: String
    var macAddress: String
    var inUse: Bool

    static func slots(from endpoints: [EngineEndpoint]) -> [GuestNic] {
        endpoints.enumerated().compactMap { index, endpoint in
            guard !endpoint.ipv4Address.isEmpty else { return nil }
            return GuestNic(
                interfaceName: "eth\(index)",
                networkID: endpoint.networkID,
                ipv4Address: endpoint.ipv4Address,
                ipv4Prefix: endpoint.ipv4Prefix,
                gateway: endpoint.gateway,
                macAddress: endpoint.macAddress,
                inUse: true
            )
        }
    }

    func asEndpoint(network: EngineNetwork, aliases: [String]) -> EngineEndpoint {
        EngineEndpoint(
            networkID: network.id,
            networkName: network.name,
            ipv4Address: ipv4Address,
            ipv4Prefix: ipv4Prefix,
            gateway: gateway,
            macAddress: macAddress,
            aliases: aliases
        )
    }
}
