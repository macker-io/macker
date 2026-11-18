import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import HelperSupport
import os

/// Control plane for bridge networks: IPAM, endpoint records, name resolution and ACL.
///
/// A Docker bridge is a Linux `bridge` + `veth`; here every container is a MicroVM whose
/// virtio-net is point-to-point with this gateway, so "same network" is a record set, not a
/// broadcast domain. Packet handling lives in ``BridgeDataplane`` so virtio RX/TX
/// does not hop onto this actor.
actor NetworkGateway {
    /// Ethernet source for every per-network gateway IP.
    static let gatewayMAC = MACAddress(0x0A00_2700_0001)
    /// Fallback when a network has no configured gateway. Builtin bridge is `172.17.0.1`.
    static let defaultGatewayIP = IPv4Address(0xAC11_0001)

    /// One container's membership in one network.
    struct Record: Sendable, Equatable {
        var containerID: String
        var containerName: String
        var hostname: String
        var networkID: String
        var networkName: String
        var ip: IPv4Address
        var gateway: IPv4Address
        var ip6: IPv6Address?
        var gateway6: IPv6Address?
        var aliases: [String]
        var internalNetwork: Bool
    }

    /// Per-container recursive resolvers from `--dns`. Empty means ``GatewayDNS.upstream``.
    private var dnsUpstreams: [String: [String]] = [:]

    private var ipam: [String: NetworkIPAM] = [:]
    private var ipam6: [String: NetworkIPAMv6] = [:]
    private var nets: [String: EngineNetwork] = [:]
    private(set) var records: [Record] = []
    private(set) var links: [String: FileHandleLink] = [:]
    private(set) var forwarder: (any GatewayForwarder)?
    private let dataplane = BridgeDataplane()
    private var utun = UtunDevice()
    private(set) var utunReady = false
    private var hostGateways: Set<String> = []

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
        if network.enableIPv6, !network.subnet6.isEmpty, !network.gateway6.isEmpty,
            ipam6[network.id] == nil,
            let table6 = try? NetworkIPAMv6(subnet: network.subnet6, gateway: network.gateway6)
        {
            ipam6[network.id] = table6
        }
        if utunReady {
            addHostRoute(network.subnet)
            if let gateway = Self.parseGateway(network) {
                addHostAddress(gateway.description)
            }
            if network.enableIPv6, !network.subnet6.isEmpty {
                addHostRoute(network.subnet6)
                if let gateway6 = Self.parseGateway6(network) {
                    addHostAddress(gateway6.description, prefix: 64)
                }
            }
        }
        publishDataplane()
    }

    func unregisterNetwork(_ id: String) {
        ipam[id] = nil
        ipam6[id] = nil
        nets[id] = nil
        publishDataplane()
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
        ipam6[networkID]?.release(id: key)
    }

    func allocate6(_ networkID: String, key: String) throws -> IPv6Address {
        guard var table = ipam6[networkID] else {
            throw EngineError.invalidArgument("no IPv6 IPAM for network")
        }
        let ip = try table.allocate(id: key)
        ipam6[networkID] = table
        return ip
    }

    func reserve6(_ networkID: String, key: String, ip: IPv6Address) throws {
        guard var table = ipam6[networkID] else {
            throw EngineError.invalidArgument("no IPv6 IPAM for network")
        }
        try table.reserve(id: key, ip: ip)
        ipam6[networkID] = table
    }

    // MARK: - Endpoints

    func bind(
        containerID: String,
        containerName: String,
        hostname: String,
        network: EngineNetwork,
        ip: IPv4Address,
        ip6: IPv6Address? = nil,
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
                gateway: Self.parseGateway(network) ?? Self.defaultGatewayIP,
                ip6: ip6,
                gateway6: Self.parseGateway6(network),
                aliases: aliases,
                internalNetwork: network.internalNetwork
            )
        )
        registerNetwork(network)
        publishDataplane()
    }

    func unbind(containerID: String, networkID: String) {
        records.removeAll { $0.containerID == containerID && $0.networkID == networkID }
        release(networkID: networkID, key: Self.endpointKey(containerID: containerID, networkID: networkID))
        publishDataplane()
    }

    /// Drops the link but keeps IPAM leases, so a restart reuses the same addresses.
    func setDNS(containerID: String, nameservers: [String]) {
        dnsUpstreams[containerID] = nameservers
        publishDataplane()
    }

    func dnsUpstreams(for containerID: String) -> [String] {
        GatewayDNS.upstreams(for: dnsUpstreams[containerID] ?? [])
    }

    func detach(containerID: String) {
        records.removeAll { $0.containerID == containerID }
        dnsUpstreams[containerID] = nil
        links.removeValue(forKey: containerID)?.stop()
        publishDataplane()
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
    func openLink(
        containerID: String,
        primary: CIDRv4,
        gateway: IPv4Address,
        ipv6: CIDRv6? = nil,
        ipv6Gateway: IPv6Address? = nil
    ) throws -> any Interface {
        if let existing = links[containerID] {
            return existing.interface
        }
        let link = try FileHandleLink(
            containerID: containerID,
            ipv4: primary,
            gateway: gateway,
            ipv6: ipv6,
            ipv6Gateway: ipv6Gateway,
            mac: try MACAddress(Self.macBytes(for: primary.address))
        )
        links[containerID] = link
        try ensureForwarder()
        publishDataplane()
        link.start { [dataplane] frame in
            dataplane.handleFrame(containerID: containerID, frame: frame)
        }
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
        return GatewayDNS.lookup(name: name, records: records, visibleNetworks: networks(of: src))
    }

    // MARK: - Published ports

    /// Binds a Mac port that relays to `guestIP:guestPort`; `-p` publishes on top of this.
    func startPortRelay(guestIP: IPv4Address, guestPort: UInt16, udp: Bool) async throws -> Int {
        try ensureForwarder()
        guard let forwarder else {
            throw EngineError.runtimeUnavailable("gateway forwarder is not ready")
        }
        let gatewayIP = records.first { $0.ip == guestIP }?.gateway ?? Self.defaultGatewayIP
        return try await forwarder.listenLocal(
            guestIP: guestIP,
            guestPort: guestPort,
            udp: udp,
            gatewayIP: gatewayIP
        )
    }

    /// `-p` target: container IP when the host route exists (PortPublisher `connect`s
    /// over utun). Without the helper, a localhost SwiftTCP relay.
    func portPublishTarget(guestIP: IPv4Address, guestPort: UInt16, udp: Bool) async throws -> (ip: String, port: Int) {
        if utunReady {
            return (guestIP.description, Int(guestPort))
        }
        let port = try await startPortRelay(guestIP: guestIP, guestPort: guestPort, udp: udp)
        return ("127.0.0.1", port)
    }

    func stopPortRelay(guestIP: IPv4Address, guestPort: UInt16, udp: Bool) {
        forwarder?.stopListenLocal(guestIP: guestIP, guestPort: guestPort, udp: udp)
    }

    // MARK: - Dataplane wiring

    /// Off-link traffic is terminated by in-process SwiftTCP.
    private func ensureForwarder() throws {
        guard forwarder == nil else { return }
        let dataplane = self.dataplane
        let onGuest: @Sendable (IPv4Address, Data) -> Void = { guestIP, packet in
            dataplane.deliver(packet, toIP: guestIP)
        }
        let onGuest6: @Sendable (IPv6Address, Data) -> Void = { guestIP, packet in
            dataplane.deliver6(packet, toIP: guestIP)
        }
        forwarder = GatewaySwiftTCP(onGuest: onGuest, onGuest6: onGuest6)
        publishDataplane()
    }

    /// Host routes into container subnets. The helper (root) opens utun and passes
    /// the fd; signed `mackerd` cannot `connect(utun)` on macOS 26. When this succeeds,
    /// `-p` can `connect` the container IP instead of a SwiftTCP localhost relay.
    private func ensureUtun() {
        guard !utunReady else { return }
        do {
            let bridges = nets.values.filter { $0.driver == "bridge" && !$0.subnet.isEmpty }
            try applyHostNet(bridges: Array(bridges))
            let dataplane = self.dataplane
            utun.start { packet in
                dataplane.handleUtun(packet)
            }
            dataplane.setUtunWriter { [utun] packet in
                utun.writeIP(packet)
            }
            utunReady = true
            Self.utunNote("host routes ready on \(utun.name)")
        } catch {
            Self.utunNote("unavailable: \(error.localizedDescription)")
            utun.closeDevice()
            utunReady = false
        }
    }

    private func applyHostNet(bridges: [EngineNetwork]) throws {
        let gateways = bridges.compactMap { Self.parseGateway($0)?.description }
        let routes = bridges.map(\.subnet) + bridges.compactMap { $0.enableIPv6 && !$0.subnet6.isEmpty ? $0.subnet6 : nil }
        guard let address = gateways.first else {
            throw EngineError.runtimeUnavailable("no bridge gateway for utun")
        }
        do {
            let attached = try HelperClient.attach(
                address: address,
                peer: address,
                prefix: 32,
                routes: routes
            )
            utun.adopt(fd: attached.fd, name: attached.name)
        } catch {
            Self.utunNote("helper attach failed: \(error.localizedDescription)")
            guard geteuid() == 0 else { throw error }
            try utun.open()
            try utun.configure(address: address, peer: address, prefix: 32)
            for subnet in routes {
                utun.addRoute(subnet: subnet)
            }
        }
        hostGateways = [address]
        for extra in gateways.dropFirst() {
            addHostAddress(extra)
        }
        for bridge in bridges where bridge.enableIPv6 && !bridge.gateway6.isEmpty {
            addHostAddress(bridge.gateway6, prefix: 64)
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

    private func addHostAddress(_ address: String, prefix: Int = 32) {
        guard hostGateways.insert(address).inserted else { return }
        do {
            try HelperClient.addAddress(
                interface: utun.name,
                address: address,
                peer: address,
                prefix: prefix
            )
        } catch {
            if geteuid() == 0 {
                try? HostNetCommands.addAddress(
                    interface: utun.name,
                    address: address,
                    peer: address,
                    prefix: prefix
                )
            } else {
                hostGateways.remove(address)
                Self.utunNote("add-address \(address) failed: \(error.localizedDescription)")
            }
        }
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
        dataplane.setUtunWriter(nil)
        utun.closeDevice()
        utunReady = false
        hostGateways.removeAll()
    }

    private func publishDataplane() {
        let gateways = gatewayIPs()
        let gateways6 = gatewayIPv6s()
        dataplane.update(
            records: records,
            dnsUpstreams: dnsUpstreams,
            links: links,
            forwarder: forwarder,
            gateways: gateways,
            gateways6: gateways6
        )
        (forwarder as? GatewaySwiftTCP)?.setGateways(gateways)
        (forwarder as? GatewaySwiftTCP)?.setGateways6(gateways6)
    }

    private func gatewayIPs() -> Set<UInt32> {
        Set(nets.values.compactMap { Self.parseGateway($0)?.value })
    }

    private func gatewayIPv6s() -> Set<IPv6Key> {
        Set(nets.values.compactMap { Self.parseGateway6($0).map(IPv6Key.init) })
    }

    static func parseGateway(_ network: EngineNetwork) -> IPv4Address? {
        guard !network.gateway.isEmpty else { return nil }
        return try? IPv4Address(network.gateway)
    }

    static func parseGateway6(_ network: EngineNetwork) -> IPv6Address? {
        guard !network.gateway6.isEmpty else { return nil }
        return try? IPv6Address(network.gateway6)
    }

    // MARK: - Helpers

    /// Every network the owner of `ip` is attached to.
    func networks(of ip: IPv4Address) -> Set<String> {
        let containers = Set(records.filter { $0.ip == ip }.map(\.containerID))
        return Set(records.filter { containers.contains($0.containerID) }.map(\.networkID))
    }

    /// Locally administered MAC derived from the address, stable across restarts.
    private static func macBytes(for ip: IPv4Address) -> [UInt8] {
        let bytes = ip.bytes
        return [0x0A, 0x00, 0x27, bytes[1], bytes[2], bytes[3]]
    }
}
