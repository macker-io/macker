import ContainerizationExtras
import Foundation

/// Allocates container addresses from a Docker-style IPv4 subnet.
/// Skips the network address, the conventional gateway (`.1`), and broadcast.
///
/// Allocation always restarts at the low end, so a released address is handed out again
/// instead of walking the subnet; container IPs stay stable and predictable across restarts.
struct NetworkIPAM: Sendable {
    let cidr: CIDRv4
    private var byID: [String: IPv4Address]
    private var used: Set<IPv4Address>

    var gateway: IPv4Address { cidr.gateway }

    /// First allocatable address: `lower` is the network address and `lower + 1` the gateway.
    private var lower: UInt32 { cidr.lower.value + 2 }

    init(subnet: String) throws {
        self.cidr = try CIDRv4(subnet)
        self.byID = [:]
        self.used = []
    }

    mutating func allocate(id: String) throws -> IPv4Address {
        if let existing = byID[id] {
            return existing
        }
        let upper = cidr.upper.value
        guard lower < upper else {
            throw EngineError.invalidArgument("no free addresses in \(cidr)")
        }
        for candidate in lower..<upper {
            let ip = IPv4Address(candidate)
            guard !used.contains(ip) else { continue }
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
        guard cidr.contains(ip), ip != cidr.lower, ip != cidr.upper, ip != gateway else {
            throw EngineError.invalidArgument("address \(ip) is not allocatable in \(cidr)")
        }
        byID[id] = ip
        used.insert(ip)
    }

    mutating func release(id: String) {
        guard let ip = byID.removeValue(forKey: id) else { return }
        used.remove(ip)
    }

    func address(for id: String) -> IPv4Address? {
        byID[id]
    }
}
