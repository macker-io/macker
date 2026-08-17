import Containerization
import ContainerizationExtras
import Foundation

/// Control plane for bridge networks: IPAM, endpoint records, name resolution and ACL.
///
/// A Docker bridge is a Linux `bridge` + `veth`; here every container is a MicroVM whose
/// virtio-net is point-to-point with this gateway, so "same network" is a record set, not a
/// broadcast domain. Packet handling lives in `NetworkGateway+Dataplane.swift`.
actor NetworkGateway {
    /// The address the guest sees as gateway *and* resolver.
    static let gatewayAddress = IPv4Address(0xC0A8_FF01) // 192.168.255.1
    static let gatewayMAC = MACAddress(0x0A00_2700_0001)

    /// One container's membership in one network.
    struct Record: Sendable, Equatable {
        var containerID: String
        var containerName: String
        var hostname: String
        var networkID: String
        var networkName: String
        var ip: IPv4Address
        var aliases: [String]
        var internalNetwork: Bool
    }

    private var ipam: [String: NetworkIPAM] = [:]
    private var nets: [String: EngineNetwork] = [:]
    private(set) var records: [Record] = []
    private(set) var links: [String: FileHandleLink] = [:]
    private(set) var forwarder: (any GatewayForwarder)?
    private var utun = UtunDevice()
    private(set) var utunReady = false
    private var ipID: UInt16 = 1

    /// IPAM handle for one container on one network.
    static func endpointKey(containerID: String, networkID: String) -> String {
        "\(containerID):\(networkID)"
    }

    // MARK: - Networks

    func registerNetwork(_ network: EngineNetwork) {
        nets[network.id] = network
        guard network.driver == "bridge", !network.subnet.isEmpty else { return }
        if ipam[network.id] == nil, let table = try? NetworkIPAM(subnet: network.subnet) {
            ipam[network.id] = table
        }
        if utunReady {
            utun.addRoute(subnet: network.subnet)
        }
    }

    func unregisterNetwork(_ id: String) {
        ipam[id] = nil
        nets[id] = nil
    }

    // MARK: - IPAM

    func allocate(_ networkID: String, key: String) throws -> IPv4Address {
        guard var table = ipam[networkID] else {
            throw EngineError.invalidArgument("no IPAM for network")
        }
        let ip = try table.allocate(id: key)
        ipam[networkID] = table
        return ip
    }

    func reserve(_ networkID: String, key: String, ip: IPv4Address) throws {
        guard var table = ipam[networkID] else {
            throw EngineError.invalidArgument("no IPAM for network")
        }
        try table.reserve(id: key, ip: ip)
        ipam[networkID] = table
    }

    func release(networkID: String, key: String) {
        ipam[networkID]?.release(id: key)
    }

    // MARK: - Endpoints

    func bind(
        containerID: String,
        containerName: String,
        hostname: String,
        network: EngineNetwork,
        ip: IPv4Address,
        aliases: [String]
    ) {
        records.removeAll { $0.containerID == containerID && $0.networkID == network.id }
        records.append(
            Record(
                containerID: containerID,
                containerName: containerName,
                hostname: hostname,
                networkID: network.id,
                networkName: network.name,
                ip: ip,
                aliases: aliases,
                internalNetwork: network.internalNetwork
            )
        )
        registerNetwork(network)
    }

    func unbind(containerID: String, networkID: String) {
        records.removeAll { $0.containerID == containerID && $0.networkID == networkID }
        release(networkID: networkID, key: Self.endpointKey(containerID: containerID, networkID: networkID))
    }

    /// Drops the link but keeps IPAM leases, so a restart reuses the same addresses.
    func detach(containerID: String) {
        records.removeAll { $0.containerID == containerID }
        links.removeValue(forKey: containerID)?.stop()
    }

    /// Drops the link and returns the addresses to IPAM.
    func forget(containerID: String) {
        for record in records where record.containerID == containerID {
            release(
                networkID: record.networkID,
                key: Self.endpointKey(containerID: containerID, networkID: record.networkID)
            )
        }
        detach(containerID: containerID)
    }

    /// Opens the guest's single virtio-net link. Extra bridge networks reuse it with another `/32`.
    func openLink(containerID: String, primary: CIDRv4) throws -> any Interface {
        if let existing = links[containerID] {
            return existing.interface
        }
        let link = try FileHandleLink(
            containerID: containerID,
            ipv4: primary,
            gateway: Self.gatewayAddress,
            mac: try MACAddress(Self.macBytes(for: primary.address))
        )
        links[containerID] = link
        link.start { [id = containerID] frame in
            Task { await self.handleFrame(containerID: id, frame: frame) }
        }
        ensureForwarder()
        ensureUtun()
        return link.interface
    }

    // MARK: - Policy

    /// Same-network check for container-to-container traffic.
    func canForward(src: IPv4Address, dst: IPv4Address) -> Bool {
        !networks(of: src).isDisjoint(with: networks(of: dst))
    }

    /// A container on `--internal` networks only never leaves the gateway.
    func allowsOutbound(src: IPv4Address) -> Bool {
        guard let owner = records.first(where: { $0.ip == src })?.containerID else { return false }
        return records.contains { $0.containerID == owner && !$0.internalNetwork }
    }

    /// Resolves a name against the networks the caller is attached to.
    func lookup(name: String, from src: IPv4Address) -> IPv4Address? {
        let needle = name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !needle.isEmpty else { return nil }
        let visible = networks(of: src)
        return match(needle, in: records.filter { visible.contains($0.networkID) })
    }

    // MARK: - Published ports

    /// Binds a Mac port that relays to `guestIP:guestPort`; `-p` publishes on top of this.
    func startPortRelay(guestIP: IPv4Address, guestPort: UInt16, udp: Bool) async throws -> Int {
        ensureForwarder()
        guard let forwarder else {
            throw EngineError.runtimeUnavailable("gateway forwarder is not ready")
        }
        return try await forwarder.listenLocal(guestIP: guestIP, guestPort: guestPort, udp: udp)
    }

    // MARK: - Dataplane wiring

    /// Today this is the userspace NAT. A privileged utun + `pf` forwarder can take its place
    /// without touching anything above.
    private func ensureForwarder() {
        guard forwarder == nil else { return }
        forwarder = GatewayNAT { [weak self] guestIP, packet in
            Task { await self?.deliver(packet, toIP: guestIP) }
        }
    }

    /// Best effort: gives the Mac a route into container subnets. Needs privileges we may not
    /// have, and nothing here depends on it — `-p` works either way.
    private func ensureUtun() {
        guard !utunReady else { return }
        do {
            try utun.open()
            try utun.configure(
                address: Self.gatewayAddress.description,
                peer: Self.gatewayAddress.description,
                prefix: 32
            )
            utun.start { [weak self] packet in
                Task { await self?.handleUtun(packet) }
            }
            utunReady = true
            for network in nets.values where network.driver == "bridge" && !network.subnet.isEmpty {
                utun.addRoute(subnet: network.subnet)
            }
        } catch {
            utunReady = false
        }
    }

    func writeToUtun(_ packet: Data) {
        guard utunReady else { return }
        utun.writeIP(packet)
    }

    /// Daemon exit: drop relays, flows and the host device. A kernel forwarder will need this to
    /// remove the `pf` rules and routes it installed.
    func shutdown() {
        forwarder?.closeAll()
        forwarder = nil
        for containerID in Array(links.keys) {
            detach(containerID: containerID)
        }
        utun.closeDevice()
        utunReady = false
    }

    // MARK: - Helpers

    /// Every network the owner of `ip` is attached to.
    func networks(of ip: IPv4Address) -> Set<String> {
        let containers = Set(records.filter { $0.ip == ip }.map(\.containerID))
        return Set(records.filter { containers.contains($0.containerID) }.map(\.networkID))
    }

    func nextID() -> UInt16 {
        ipID &+= 1
        return ipID
    }

    private func match(_ needle: String, in records: [Record]) -> IPv4Address? {
        for record in records {
            let names = [record.containerName, record.hostname, String(record.containerID.prefix(12))]
                + record.aliases
            for raw in names {
                let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                if name == needle || "\(name).\(record.networkName)" == needle {
                    return record.ip
                }
            }
            if needle.count >= 12, record.containerID.lowercased().hasPrefix(needle) {
                return record.ip
            }
        }
        return nil
    }

    /// Locally administered MAC derived from the address, stable across restarts.
    private static func macBytes(for ip: IPv4Address) -> [UInt8] {
        let bytes = ip.bytes
        return [0x0A, 0x00, 0x27, bytes[1], bytes[2], bytes[3]]
    }
}
