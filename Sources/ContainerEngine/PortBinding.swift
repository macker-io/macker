import Foundation

public struct EnginePortBinding: Sendable, Codable, Equatable {
    public var hostIP: String
    public var hostPort: Int
    public var containerPort: Int
    public var protocolName: String

    public var dockerKey: String { "\(containerPort)/\(protocolName)" }

    /// Go `net.JoinHostPort`: IPv6 addresses are wrapped in brackets.
    public var joinedHostPort: String {
        hostIP.contains(":") ? "[\(hostIP)]:\(hostPort)" : "\(hostIP):\(hostPort)"
    }

    public var dockerPortLine: String { "\(dockerKey) -> \(joinedHostPort)" }

    /// `docker ps` PORTS cell: `0.0.0.0:18080->80/tcp`, or `80/tcp` when unpublished.
    public var psDisplay: String {
        if hostPort > 0 {
            let ip = hostIP.isEmpty ? "0.0.0.0" : hostIP
            let host = ip.contains(":") ? "[\(ip)]:\(hostPort)" : "\(ip):\(hostPort)"
            return "\(host)->\(containerPort)/\(protocolName)"
        }
        return dockerKey
    }

    public static func psColumn(_ bindings: [EnginePortBinding]) -> String {
        bindings.map(\.psDisplay).joined(separator: ", ")
    }

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

        let (rest, protocolName) = splitTrailingProtocol(trimmed)
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
        let (portPart, protocolName) = splitTrailingProtocol(trimmed)
        guard protocolName == "tcp" || protocolName == "udp" else {
            throw EngineError.invalidArgument("invalid exposed port protocol in \(key)")
        }
        let port = try parsePort(portPart, spec: key)
        guard (1...65535).contains(port) else {
            throw EngineError.invalidArgument("invalid exposed port \(key)")
        }
        return EnginePortBinding(hostIP: "", hostPort: port, containerPort: port, protocolName: protocolName)
    }

    /// `docker port` private-port argument: `80`, `80/tcp`, `80/`. Empty protocol defaults to tcp.
    public static func parsePrivatePortKey(_ spec: String) throws -> String {
        var portPart = spec
        var proto = "tcp"
        if let slash = spec.firstIndex(of: "/") {
            portPart = String(spec[..<slash])
            let rest = String(spec[spec.index(after: slash)...])
            if !rest.isEmpty {
                proto = rest.lowercased()
            }
        }
        guard let value = UInt64(portPart), value <= UInt64(UInt16.max) else {
            throw EngineError.invalidArgument("Invalid private port '\(spec)'")
        }
        return "\(value)/\(proto)"
    }

    /// True when both bindings would claim the same host socket: same protocol and port, and
    /// the addresses overlap (equal, or either is a wildcard). Ephemeral (`0`) never conflicts.
    public func conflicts(with other: EnginePortBinding) -> Bool {
        guard hostPort != 0, hostPort == other.hostPort,
            protocolName.lowercased() == other.protocolName.lowercased()
        else { return false }
        // "" listens on every family; otherwise IPv4 and IPv6 sockets are independent.
        func isV6(_ ip: String) -> Bool { ip.contains(":") }
        if !hostIP.isEmpty, !other.hostIP.isEmpty, isV6(hostIP) != isV6(other.hostIP) {
            return false
        }
        let wildcard: Set<String> = ["", "0.0.0.0", "::"]
        return wildcard.contains(hostIP) || wildcard.contains(other.hostIP) || hostIP == other.hostIP
    }

    /// Docker's port-allocator wording for a host port already claimed by another container.
    public var allocatedError: String {
        let ip = hostIP.isEmpty ? "0.0.0.0" : hostIP
        let host = ip.contains(":") ? "[\(ip)]" : ip
        return "Bind for \(host):\(hostPort) failed: port is already allocated"
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

    /// All mappings (`80/tcp -> 0.0.0.0:8080`), or just host addresses for one private port.
    /// Multiple host bindings for the same container port are kept (unlike ``merging``).
    public static func dockerPortLines(
        _ bindings: [EnginePortBinding],
        privatePort: String?,
        container: String
    ) throws -> [String] {
        if let privatePort {
            let key = try parsePrivatePortKey(privatePort)
            let hosts = bindings.filter { $0.dockerKey == key }
            guard !hosts.isEmpty else {
                throw EngineError.invalidArgument("No public port '\(key)' published for \(container)")
            }
            return hosts.map(\.joinedHostPort)
        }
        return bindings.map(\.dockerPortLine).sorted()
    }

    private static func splitTrailingProtocol(_ spec: String) -> (rest: String, protocolName: String) {
        guard let slash = spec.lastIndex(of: "/") else {
            return (spec, "tcp")
        }
        return (String(spec[..<slash]), String(spec[spec.index(after: slash)...]).lowercased())
    }

    private static func parsePort(_ raw: String, spec: String) throws -> Int {
        guard let value = Int(raw), (0...65535).contains(value) else {
            throw EngineError.invalidArgument("invalid port in publish spec: \(spec)")
        }
        return value
    }
}
