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
    public var options: [String: String]
    public var ipRange: String
    public var auxiliaryAddresses: [String: String]
    public var ipamDriver: String
    public var ipamOptions: [String: String]
    public var enableIPv4: Bool
    public var enableIPv6: Bool

    public init(
        id: String,
        name: String,
        driver: String,
        scope: String,
        created: Date,
        labels: [String: String],
        subnet: String,
        gateway: String,
        internalNetwork: Bool,
        builtin: Bool,
        options: [String: String] = [:],
        ipRange: String = "",
        auxiliaryAddresses: [String: String] = [:],
        ipamDriver: String = "default",
        ipamOptions: [String: String] = [:],
        enableIPv4: Bool = true,
        enableIPv6: Bool = false
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
        self.created = created
        self.labels = labels
        self.subnet = subnet
        self.gateway = gateway
        self.internalNetwork = internalNetwork
        self.builtin = builtin
        self.options = options
        self.ipRange = ipRange
        self.auxiliaryAddresses = auxiliaryAddresses
        self.ipamDriver = ipamDriver
        self.ipamOptions = ipamOptions
        self.enableIPv4 = enableIPv4
        self.enableIPv6 = enableIPv6
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        driver = try container.decode(String.self, forKey: .driver)
        scope = try container.decode(String.self, forKey: .scope)
        created = try container.decode(Date.self, forKey: .created)
        labels = try container.decode([String: String].self, forKey: .labels)
        subnet = try container.decode(String.self, forKey: .subnet)
        gateway = try container.decode(String.self, forKey: .gateway)
        internalNetwork = try container.decode(Bool.self, forKey: .internalNetwork)
        builtin = try container.decode(Bool.self, forKey: .builtin)
        options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
        ipRange = try container.decodeIfPresent(String.self, forKey: .ipRange) ?? ""
        auxiliaryAddresses = try container.decodeIfPresent([String: String].self, forKey: .auxiliaryAddresses) ?? [:]
        ipamDriver = try container.decodeIfPresent(String.self, forKey: .ipamDriver) ?? "default"
        ipamOptions = try container.decodeIfPresent([String: String].self, forKey: .ipamOptions) ?? [:]
        enableIPv4 = try container.decodeIfPresent(Bool.self, forKey: .enableIPv4) ?? true
        enableIPv6 = try container.decodeIfPresent(Bool.self, forKey: .enableIPv6) ?? false
    }
}

public struct EngineEndpoint: Sendable, Codable, Equatable {
    public var networkID: String
    public var networkName: String
    public var ipv4Address: String
    public var ipv4Prefix: Int
    public var gateway: String
    public var macAddress: String
    public var aliases: [String]
    public var driverOpts: [String: String]
    public var gwPriority: Int
    public var linkLocalIPs: [String]

    public init(
        networkID: String,
        networkName: String,
        ipv4Address: String,
        ipv4Prefix: Int,
        gateway: String,
        macAddress: String,
        aliases: [String],
        driverOpts: [String: String] = [:],
        gwPriority: Int = 0,
        linkLocalIPs: [String] = []
    ) {
        self.networkID = networkID
        self.networkName = networkName
        self.ipv4Address = ipv4Address
        self.ipv4Prefix = ipv4Prefix
        self.gateway = gateway
        self.macAddress = macAddress
        self.aliases = aliases
        self.driverOpts = driverOpts
        self.gwPriority = gwPriority
        self.linkLocalIPs = linkLocalIPs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkID = try container.decode(String.self, forKey: .networkID)
        networkName = try container.decode(String.self, forKey: .networkName)
        ipv4Address = try container.decode(String.self, forKey: .ipv4Address)
        ipv4Prefix = try container.decode(Int.self, forKey: .ipv4Prefix)
        gateway = try container.decode(String.self, forKey: .gateway)
        macAddress = try container.decode(String.self, forKey: .macAddress)
        aliases = try container.decode([String].self, forKey: .aliases)
        driverOpts = try container.decodeIfPresent([String: String].self, forKey: .driverOpts) ?? [:]
        gwPriority = try container.decodeIfPresent(Int.self, forKey: .gwPriority) ?? 0
        linkLocalIPs = try container.decodeIfPresent([String].self, forKey: .linkLocalIPs) ?? []
    }
}

public struct EngineEndpointRequest: Sendable {
    public var network: String
    public var aliases: [String]
    public var ipv4: String?
    public var macAddress: String?
    public var driverOpts: [String: String]
    public var gwPriority: Int
    public var linkLocalIPs: [String]

    public init(
        network: String,
        aliases: [String] = [],
        ipv4: String? = nil,
        macAddress: String? = nil,
        driverOpts: [String: String] = [:],
        gwPriority: Int = 0,
        linkLocalIPs: [String] = []
    ) {
        self.network = network
        self.aliases = aliases
        self.ipv4 = ipv4
        self.macAddress = macAddress
        self.driverOpts = driverOpts
        self.gwPriority = gwPriority
        self.linkLocalIPs = linkLocalIPs
    }
}

public struct EngineNetworkCreateSpec: Sendable {
    public var name: String?
    public var driver: String
    public var labels: [String: String]
    public var options: [String: String]
    public var subnet: String?
    public var gateway: String?
    public var ipRange: String?
    public var auxiliaryAddresses: [String: String]
    public var ipamDriver: String
    public var ipamOptions: [String: String]
    public var enableIPv4: Bool
    public var enableIPv6: Bool
    public var internalNetwork: Bool

    public init(
        name: String? = nil,
        driver: String = "bridge",
        labels: [String: String] = [:],
        options: [String: String] = [:],
        subnet: String? = nil,
        gateway: String? = nil,
        ipRange: String? = nil,
        auxiliaryAddresses: [String: String] = [:],
        ipamDriver: String = "default",
        ipamOptions: [String: String] = [:],
        enableIPv4: Bool = true,
        enableIPv6: Bool = false,
        internalNetwork: Bool = false
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.options = options
        self.subnet = subnet
        self.gateway = gateway
        self.ipRange = ipRange
        self.auxiliaryAddresses = auxiliaryAddresses
        self.ipamDriver = ipamDriver
        self.ipamOptions = ipamOptions
        self.enableIPv4 = enableIPv4
        self.enableIPv6 = enableIPv6
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
    public var ipv4: String?
    public var ipv6: String?
    public var driverOpts: [String: String]
    public var gwPriority: Int
    public var linkLocalIPs: [String]

    public init(
        container: String,
        aliases: [String] = [],
        ipv4: String? = nil,
        ipv6: String? = nil,
        driverOpts: [String: String] = [:],
        gwPriority: Int = 0,
        linkLocalIPs: [String] = []
    ) {
        self.container = container
        self.aliases = aliases
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.driverOpts = driverOpts
        self.gwPriority = gwPriority
        self.linkLocalIPs = linkLocalIPs
    }

    func asRequest(network: String) -> EngineEndpointRequest {
        EngineEndpointRequest(
            network: network,
            aliases: aliases,
            ipv4: ipv4,
            driverOpts: driverOpts,
            gwPriority: gwPriority,
            linkLocalIPs: linkLocalIPs
        )
    }
}

/// Guest virtio-net slots. Bridge endpoints share eth0; host keeps its own NIC.
/// VZ cannot hot-plug, so a running connect to a new driver still needs a stop/start.
struct GuestNic: Sendable {
    var interfaceName: String
    var networkID: String
    var ipv4Address: String
    var ipv4Prefix: Int
    var gateway: String
    var macAddress: String
    var inUse: Bool

    func asEndpoint(
        network: EngineNetwork,
        aliases: [String],
        driverOpts: [String: String] = [:],
        gwPriority: Int = 0,
        linkLocalIPs: [String] = []
    ) -> EngineEndpoint {
        EngineEndpoint(
            networkID: network.id,
            networkName: network.name,
            ipv4Address: ipv4Address,
            ipv4Prefix: ipv4Prefix,
            gateway: gateway,
            macAddress: macAddress,
            aliases: aliases,
            driverOpts: driverOpts,
            gwPriority: gwPriority,
            linkLocalIPs: linkLocalIPs
        )
    }
}
