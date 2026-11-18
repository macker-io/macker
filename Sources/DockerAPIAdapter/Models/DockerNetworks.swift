import ContainerEngine
import Foundation

public struct DockerNetwork: Encodable, Sendable {
    public let Name: String
    public let Id: String
    public let Created: String
    public let Scope: String
    public let Driver: String
    public let EnableIPv4: Bool
    public let EnableIPv6: Bool
    public let IPAM: IPAM
    public let Internal: Bool
    public let Attachable: Bool
    public let Ingress: Bool
    public let Containers: [String: Container]
    public let Options: [String: String]
    public let Labels: [String: String]

    public struct IPAM: Encodable, Sendable {
        public let Driver: String
        public let Config: [Config]
        public let Options: [String: String]

        public struct Config: Encodable, Sendable {
            public let Subnet: String
            public let IPRange: String
            public let Gateway: String
            public let AuxiliaryAddresses: [String: String]
        }
    }

    public struct Container: Encodable, Sendable {
        public let Name: String
        public let EndpointID: String
        public let MacAddress: String
        public let IPv4Address: String
        public let IPv6Address: String
    }

    public init(_ inspect: EngineNetworkInspect) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let network = inspect.network
        self.Name = network.name
        self.Id = network.id
        self.Created = iso.string(from: network.created)
        self.Scope = network.scope
        self.Driver = network.driver
        self.EnableIPv4 = network.enableIPv4
        self.EnableIPv6 = network.enableIPv6
        var ipamConfigs: [IPAM.Config] = []
        if !network.subnet.isEmpty {
            ipamConfigs.append(
                .init(
                    Subnet: network.subnet,
                    IPRange: network.ipRange,
                    Gateway: network.gateway,
                    AuxiliaryAddresses: network.auxiliaryAddresses
                )
            )
        }
        if !network.subnet6.isEmpty {
            ipamConfigs.append(
                .init(
                    Subnet: network.subnet6,
                    IPRange: "",
                    Gateway: network.gateway6,
                    AuxiliaryAddresses: [:]
                )
            )
        }
        self.IPAM = .init(
            Driver: network.ipamDriver,
            Config: ipamConfigs,
            Options: network.ipamOptions
        )
        self.Internal = network.internalNetwork
        self.Attachable = false
        self.Ingress = false
        self.Containers = Dictionary(uniqueKeysWithValues: inspect.containers.map { item in
            (
                item.id,
                Container(
                    Name: item.name,
                    EndpointID: item.endpointID,
                    MacAddress: item.macAddress,
                    IPv4Address: item.ipv4Address,
                    IPv6Address: item.ipv6Address
                )
            )
        })
        self.Options = network.options
        self.Labels = network.labels
    }
}

public struct DockerCreateNetworkRequest: Decodable, Sendable {
    public let Name: String?
    public let Driver: String?
    public let Internal: Bool?
    public let EnableIPv4: Bool?
    public let EnableIPv6: Bool?
    public let Labels: [String: String]?
    public let Options: [String: String]?
    public let IPAM: IPAM?

    public init(
        Name: String? = nil,
        Driver: String? = nil,
        Internal: Bool? = nil,
        EnableIPv4: Bool? = nil,
        EnableIPv6: Bool? = nil,
        Labels: [String: String]? = nil,
        Options: [String: String]? = nil,
        IPAM: IPAM? = nil
    ) {
        self.Name = Name
        self.Driver = Driver
        self.Internal = Internal
        self.EnableIPv4 = EnableIPv4
        self.EnableIPv6 = EnableIPv6
        self.Labels = Labels
        self.Options = Options
        self.IPAM = IPAM
    }

    public struct IPAM: Decodable, Sendable {
        public let Driver: String?
        public let Config: [Config]?
        public let Options: [String: String]?

        public struct Config: Decodable, Sendable {
            public let Subnet: String?
            public let IPRange: String?
            public let Gateway: String?
            public let AuxiliaryAddresses: [String: String]?
        }
    }
}

public struct DockerCreateNetworkResponse: Encodable, Sendable {
    public let Id: String
    public let Warning: String
}

public struct DockerConnectNetworkRequest: Decodable, Sendable {
    public let Container: String?
    public let EndpointConfig: DockerEndpointConfig?
}

public struct DockerDisconnectNetworkRequest: Decodable, Sendable {
    public let Container: String?
    public let Force: Bool?
}

public struct DockerNetworkPruneResponse: Encodable, Sendable {
    public let NetworksDeleted: [String]
}
