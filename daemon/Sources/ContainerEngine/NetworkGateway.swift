import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import MackerHelperSupport
import os

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
        if ipam[network.id] == nil, let table = try? NetworkIPAM(network: network) {
            ipam[network.id] = table
        }
        if utunReady {
            addHostRoute(network.subnet)
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
        try ensureForwarder()
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
        try ensureForwarder()
        guard let forwarder else {
            throw EngineError.runtimeUnavailable("gateway forwarder is not ready")
        }
        return try await forwarder.listenLocal(guestIP: guestIP, guestPort: guestPort, udp: udp)
    }

    func stopPortRelay(guestIP: IPv4Address, guestPort: UInt16, udp: Bool) {
        forwarder?.stopListenLocal(guestIP: guestIP, guestPort: guestPort, udp: udp)
    }

    // MARK: - Dataplane wiring

    /// Off-link traffic is terminated by the in-process lwIP forwarder.
    private func ensureForwarder() throws {
        guard forwarder == nil else { return }
        let onGuest: @Sendable (IPv4Address, Data) -> Void = { [weak self] guestIP, packet in
            Task { await self?.deliver(packet, toIP: guestIP) }
        }
        guard let stack = GatewayLwIP(onGuest: onGuest) else {
            throw EngineError.runtimeUnavailable("failed to start lwIP gateway forwarder")
        }
        forwarder = stack
    }

    /// Host routes into container subnets. The helper (root) opens utun and passes
    /// the fd; signed `mackerd` cannot `connect(utun)` on macOS 26. `-p` does not need this.
    private func ensureUtun() {
        guard !utunReady else { return }
        do {
            let routes = nets.values
                .filter { $0.driver == "bridge" && !$0.subnet.isEmpty }
                .map(\.subnet)
            try applyHostNet(routes: routes)
            utun.start { [weak self] packet in
                Task { await self?.handleUtun(packet) }
            }
            utunReady = true
            Self.utunNote("host routes ready on \(utun.name)")
        } catch {
            Self.utunNote("unavailable: \(error.localizedDescription)")
            utun.closeDevice()
            utunReady = false
        }
    }

    private func applyHostNet(routes: [String]) throws {
        let address = Self.gatewayAddress.description
        do {
            let attached = try HelperClient.attach(
                address: address,
                peer: address,
                prefix: 32,
                routes: routes
            )
            utun.adopt(fd: attached.fd, name: attached.name)
            return
        } catch {
            Self.utunNote("helper attach failed: \(error.localizedDescription)")
            guard geteuid() == 0 else { throw error }
        }
        try utun.open()
        try utun.configure(address: address, peer: address, prefix: 32)
        for subnet in routes {
            utun.addRoute(subnet: subnet)
        }
    }

    private func addHostRoute(_ subnet: String) {
        do {
            try HelperClient.addRoute(interface: utun.name, subnet: subnet)
        } catch {
            if geteuid() == 0 {
                utun.addRoute(subnet: subnet)
            } else {
                Self.utunNote("add-route \(subnet) failed: \(error.localizedDescription)")
            }
        }
    }

    func writeToUtun(_ packet: Data) {
        guard utunReady else { return }
        utun.writeIP(packet)
    }

    private static let utunLog = Logger(subsystem: "io.macker.daemon", category: "utun")

    private static func utunNote(_ message: String) {
        fputs("macker utun: \(message)\n", stderr)
        fflush(stderr)
        utunLog.notice("\(message, privacy: .public)")
    }

    /// Daemon exit: drop relays, flows, host routes, and the utun fd.
    func shutdown() {
        forwarder?.closeAll()
        forwarder = nil
        for containerID in Array(links.keys) {
            detach(containerID: containerID)
        }
        if utunReady, !utun.name.isEmpty {
            try? HelperClient.teardown(interface: utun.name)
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
