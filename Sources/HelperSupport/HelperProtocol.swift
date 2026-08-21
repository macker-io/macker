import Darwin
import Foundation

/// JSON line protocol between `mackerd` and `macker-helper`.
public enum HelperOperation: String, Codable, Sendable {
    case ping
    case attach
    case addRoute = "add-route"
    case teardown
}

public struct HelperRequest: Codable, Sendable, Equatable {
    public var op: HelperOperation
    public var interface: String?
    public var address: String?
    public var peer: String?
    public var prefix: Int?
    public var routes: [String]?
    public var subnet: String?

    public init(
        op: HelperOperation,
        interface: String? = nil,
        address: String? = nil,
        peer: String? = nil,
        prefix: Int? = nil,
        routes: [String]? = nil,
        subnet: String? = nil
    ) {
        self.op = op
        self.interface = interface
        self.address = address
        self.peer = peer
        self.prefix = prefix
        self.routes = routes
        self.subnet = subnet
    }

    public static var ping: HelperRequest { HelperRequest(op: .ping) }

    public static func attach(
        address: String,
        peer: String,
        prefix: Int,
        routes: [String]
    ) -> HelperRequest {
        HelperRequest(op: .attach, address: address, peer: peer, prefix: prefix, routes: routes)
    }

    public static func addRoute(interface: String, subnet: String) -> HelperRequest {
        HelperRequest(op: .addRoute, interface: interface, subnet: subnet)
    }

    public static func teardown(interface: String) -> HelperRequest {
        HelperRequest(op: .teardown, interface: interface)
    }

    /// Rejects anything the helper must not pass to `ifconfig` / `route`.
    public func validated() throws -> ValidatedHelperRequest {
        switch op {
        case .ping:
            return .ping
        case .attach:
            return .attach(
                address: try HelperNetText.requireIPv4(address, field: "address"),
                peer: try HelperNetText.requireIPv4(peer, field: "peer"),
                prefix: try HelperNetText.requirePrefix(prefix),
                routes: try (self.routes ?? []).map { try HelperNetText.requireCIDR($0) }
            )
        case .addRoute:
            return .addRoute(
                interface: try HelperNetText.requireUtun(interface),
                subnet: try HelperNetText.requireCIDR(subnet)
            )
        case .teardown:
            return .teardown(interface: try HelperNetText.requireUtun(interface))
        }
    }
}

/// Post-validation command. Wire JSON stays in ``HelperRequest``.
public enum ValidatedHelperRequest: Sendable, Equatable {
    case ping
    case attach(address: String, peer: String, prefix: Int, routes: [String])
    case addRoute(interface: String, subnet: String)
    case teardown(interface: String)
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var version: Int?
    public var interface: String?

    public init(ok: Bool, error: String? = nil, version: Int? = nil, interface: String? = nil) {
        self.ok = ok
        self.error = error
        self.version = version
        self.interface = interface
    }

    public static let protocolVersion = 2

    public static var pong: HelperResponse {
        HelperResponse(ok: true, version: protocolVersion)
    }

    public static func failure(_ message: String) -> HelperResponse {
        HelperResponse(ok: false, error: message)
    }
}

public enum HelperNetText: Sendable {
    public static func isUtunInterface(_ name: String) -> Bool {
        guard name.hasPrefix("utun") else { return false }
        let rest = name.dropFirst(4)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    public static func isIPv4(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    public static func isIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            return false
        }
        return isIPv4(String(parts[0]))
    }

    public static func netmask(prefix: Int) -> String {
        let bits = prefix < 0 ? 0 : min(prefix, 32)
        let mask = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return "\((mask >> 24) & 0xff).\((mask >> 16) & 0xff).\((mask >> 8) & 0xff).\(mask & 0xff)"
    }

    static func requireUtun(_ name: String?) throws -> String {
        guard let name, isUtunInterface(name) else {
            throw HelperError.invalidRequest("interface must be utunN")
        }
        return name
    }

    static func requireIPv4(_ value: String?, field: String) throws -> String {
        guard let value, isIPv4(value) else {
            throw HelperError.invalidRequest("\(field) must be an IPv4 address")
        }
        return value
    }

    static func requirePrefix(_ prefix: Int?) throws -> Int {
        guard let prefix, (0...32).contains(prefix) else {
            throw HelperError.invalidRequest("prefix must be 0...32")
        }
        return prefix
    }

    static func requireCIDR(_ value: String?) throws -> String {
        guard let value, isIPv4CIDR(value) else {
            throw HelperError.invalidRequest("subnet must be IPv4 CIDR")
        }
        return value
    }
}
