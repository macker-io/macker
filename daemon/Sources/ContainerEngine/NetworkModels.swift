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

public struct EnginePortBinding: Sendable, Codable, Equatable {
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var protocolName: String

    public var dockerKey: String { "\(containerPort)/\(protocolName)" }

    public init(hostIP: String = "", hostPort: Int, containerPort: Int, protocolName: String = "tcp") {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
    }

    public static func parsePublish(_ spec: String) throws -> EnginePortBinding {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineError.invalidArgument("invalid publish spec: \(spec)")
        }

        var rest = trimmed
        var protocolName = "tcp"
        if let slash = rest.lastIndex(of: "/") {
            protocolName = String(rest[rest.index(after: slash)...]).lowercased()
            rest = String(rest[..<slash])
        }
        guard protocolName == "tcp" || protocolName == "udp" else {
            throw EngineError.invalidArgument("invalid publish protocol in \(spec)")
        }

        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let hostIP: String
        let hostPort: Int
        let containerPort: Int
        switch parts.count {
        case 1:
            hostIP = ""
            hostPort = 0
            containerPort = try parsePort(parts[0], spec: spec)
        case 2:
            hostIP = ""
            if parts[0].isEmpty {
                hostPort = 0
            } else {
                hostPort = try parsePort(parts[0], spec: spec)
            }
            containerPort = try parsePort(parts[1], spec: spec)
        case 3:
            hostIP = parts[0]
            if parts[1].isEmpty {
                hostPort = 0
            } else {
                hostPort = try parsePort(parts[1], spec: spec)
            }
            containerPort = try parsePort(parts[2], spec: spec)
        default:
            throw EngineError.invalidArgument("invalid publish spec: \(spec)")
        }
        return EnginePortBinding(
            hostIP: hostIP,
            hostPort: hostPort,
            containerPort: containerPort,
            protocolName: protocolName
        )
    }

    public static func parseExposed(_ key: String) throws -> EnginePortBinding {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineError.invalidArgument("invalid exposed port \(key)")
        }
        var protocolName = "tcp"
        var portPart = trimmed
        if let slash = trimmed.lastIndex(of: "/") {
            protocolName = String(trimmed[trimmed.index(after: slash)...]).lowercased()
            portPart = String(trimmed[..<slash])
        }
        guard protocolName == "tcp" || protocolName == "udp" else {
            throw EngineError.invalidArgument("invalid exposed port protocol in \(key)")
        }
        let port = try parsePort(portPart, spec: key)
        guard (1...65535).contains(port) else {
            throw EngineError.invalidArgument("invalid exposed port \(key)")
        }
        return EnginePortBinding(hostIP: "", hostPort: port, containerPort: port, protocolName: protocolName)
    }

    public static func uniqued(_ ports: [EnginePortBinding]) -> [EnginePortBinding] {
        merging(ports, [])
    }

    public static func merging(_ lhs: [EnginePortBinding], _ rhs: [EnginePortBinding]) -> [EnginePortBinding] {
        var byKey: [String: EnginePortBinding] = [:]
        for binding in lhs + rhs {
            byKey[binding.dockerKey] = binding
        }
        return byKey.values.sorted {
            $0.containerPort == $1.containerPort
                ? $0.protocolName < $1.protocolName
                : $0.containerPort < $1.containerPort
        }
    }

    private static func parsePort(_ raw: String, spec: String) throws -> Int {
        guard let value = Int(raw), value >= 0, value <= 65535 else {
            throw EngineError.invalidArgument("invalid port in publish spec: \(spec)")
        }
        return value
    }
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
