import ContainerizationExtras
import Foundation

/// Allocates container addresses from a Docker-style IPv4 subnet.
/// Skips the network address, the conventional gateway (`.1`), broadcast, and reserved addresses.
///
/// Allocation always restarts at the low end, so a released address is handed out again
/// instead of walking the subnet; container IPs stay stable and predictable across restarts.
struct NetworkIPAM: Sendable {
    let cidr: CIDRv4
    let pool: CIDRv4
    private var reserved: Set<IPv4Address>
    private var byID: [String: IPv4Address]
    private var used: Set<IPv4Address>

    var gateway: IPv4Address { cidr.gateway }

    init(subnet: String, ipRange: String? = nil, reserved: Set<IPv4Address> = []) throws {
        self.cidr = try CIDRv4(subnet)
        if let ipRange, !ipRange.isEmpty {
            let range = try CIDRv4(ipRange)
            guard range.lower.value >= cidr.lower.value, range.upper.value <= cidr.upper.value else {
                throw EngineError.invalidArgument("ip-range \(ipRange) is not contained in subnet \(subnet)")
            }
            self.pool = range
        } else {
            self.pool = cidr
        }
        self.reserved = reserved
        self.byID = [:]
        self.used = []
    }

    init(network: EngineNetwork) throws {
        var reserved = Set<IPv4Address>()
        if !network.gateway.isEmpty, let gateway = try? IPv4Address(network.gateway) {
            reserved.insert(gateway)
        }
        for address in network.auxiliaryAddresses.values {
            if let ip = try? IPv4Address(address) {
                reserved.insert(ip)
            }
        }
        try self.init(
            subnet: network.subnet,
            ipRange: network.ipRange.isEmpty ? nil : network.ipRange,
            reserved: reserved
        )
    }

    mutating func allocate(id: String) throws -> IPv4Address {
        if let existing = byID[id] {
            return existing
        }
        let lower = pool.lower.value
        let upper = pool.upper.value
        guard lower < upper else {
            throw EngineError.invalidArgument("no free addresses in \(cidr)")
        }
        for candidate in lower..<upper {
            let ip = IPv4Address(candidate)
            guard isAllocatable(ip) else { continue }
            byID[id] = ip
            used.insert(ip)
            return ip
        }
        throw EngineError.invalidArgument("no free addresses in \(cidr)")
    }

    /// Pins a specific address, used when restoring a container that already has one.
    mutating func reserve(id: String, ip: IPv4Address) throws {
        if let existing = byID[id] {
            if existing == ip { return }
            byID[id] = nil
            used.remove(existing)
        }
        guard !used.contains(ip) else {
            throw EngineError.conflict("address \(ip) is already allocated")
        }
        guard isAllocatable(ip) else {
            throw EngineError.invalidArgument("address \(ip) is not allocatable in \(cidr)")
        }
        byID[id] = ip
        used.insert(ip)
    }

    mutating func release(id: String) {
        guard let ip = byID.removeValue(forKey: id) else { return }
        used.remove(ip)
    }

    /// Releases every lease whose id starts with `prefix` (all endpoints of one container).
    mutating func release(idsWithPrefix prefix: String) {
        for id in byID.keys where id.hasPrefix(prefix) {
            release(id: id)
        }
    }

    func address(for id: String) -> IPv4Address? {
        byID[id]
    }

    private func isAllocatable(_ ip: IPv4Address) -> Bool {
        guard cidr.contains(ip), pool.contains(ip) else { return false }
        guard ip != cidr.lower, ip != cidr.upper, ip != gateway else { return false }
        return !reserved.contains(ip) && !used.contains(ip)
    }
}
