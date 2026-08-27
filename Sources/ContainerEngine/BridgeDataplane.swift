import ContainerizationExtras
import Foundation
import os

/// Packet path for `bridge` virtio-net. Runs off ``NetworkGateway`` (an actor): RX comes
/// from ``FileHandleLink`` queues, TX from the lwIP queue. The actor only publishes
/// IPAM / ACL / DNS snapshots here.
///
/// Same-network L3 is a peer table (IP → link + network set). The hot path takes the lock
/// only to pick a `FileHandleLink`, then `sendIPv4` — no actor hop and no full snapshot copy.
final class BridgeDataplane: @unchecked Sendable {
    private struct Peer {
        let link: FileHandleLink
        let networks: Set<String>
    }

    private struct Snapshot {
        var records: [NetworkGateway.Record] = []
        var dnsUpstreams: [String: [String]] = [:]
        var links: [String: FileHandleLink] = [:]
        var peers: [UInt32: Peer] = [:]
        var allowsOutbound: [UInt32: Bool] = [:]
        var networksOfContainer: [String: Set<String>] = [:]
        var forwarder: (any GatewayForwarder)?
        var writeUtun: (@Sendable (Data) -> Void)?
    }

    private enum IPv4Action {
        case drop
        case sameNet(FileHandleLink)
        case outbound(any GatewayForwarder)
        case toGateway(Snapshot)
    }

    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())
    private let ipID = OSAllocatedUnfairLock<UInt16>(initialState: 1)

    func update(
        records: [NetworkGateway.Record],
        dnsUpstreams: [String: [String]],
        links: [String: FileHandleLink],
        forwarder: (any GatewayForwarder)?
    ) {
        lock.withLock { state in
            state.records = records
            state.dnsUpstreams = dnsUpstreams
            state.links = links
            state.forwarder = forwarder
            state.peers.removeAll(keepingCapacity: true)
            state.allowsOutbound.removeAll(keepingCapacity: true)
            var networks: [String: Set<String>] = [:]
            var outbound: [String: Bool] = [:]
            for record in records {
                networks[record.containerID, default: []].insert(record.networkID)
                outbound[record.containerID] =
                    (outbound[record.containerID] == true) || !record.internalNetwork
            }
            state.networksOfContainer = networks
            for record in records {
                guard let link = links[record.containerID] else { continue }
                let ip = Self.address(record.ip)
                state.peers[ip] = Peer(link: link, networks: networks[record.containerID] ?? [])
                state.allowsOutbound[ip] = outbound[record.containerID] == true
            }
        }
    }

    func setUtunWriter(_ writer: (@Sendable (Data) -> Void)?) {
        lock.withLock { $0.writeUtun = writer }
    }

    func handleFrame(containerID: String, frame: UnsafeRawBufferPointer) {
        guard let type = IPv4Peek.ethernetType(frame) else { return }
        switch type {
        case Ethernet.typeARP:
            handleARP(containerID: containerID, frame: frame)
        case Ethernet.typeIPv4:
            guard let range = IPv4Peek.ipv4Range(inEthernet: frame) else { return }
            handleIPv4(UnsafeRawBufferPointer(rebasing: frame[range]), from: containerID)
        default:
            break
        }
    }

    func handleUtun(_ packet: UnsafeRawBufferPointer) {
        guard let header = IPv4Peek.tuple(packet) else { return }
        deliver(packet, toIP: header.dst)
    }

    func deliver(_ packet: Data, toIP ip: IPv4Address) {
        packet.withUnsafeBytes { deliver($0, toIP: Self.address(ip)) }
    }

    private func handleARP(containerID: String, frame: UnsafeRawBufferPointer) {
        guard let request = ARP.parseEthernetRequest(frame, gateway: NetworkGateway.gatewayAddress) else {
            return
        }
        let reply = ARP.reply(
            senderMAC: NetworkGateway.gatewayMAC,
            senderIP: NetworkGateway.gatewayAddress,
            targetMAC: request.srcMAC,
            targetIP: request.senderIP
        )
        let ethernet = Ethernet.frame(
            dst: request.srcMAC,
            src: NetworkGateway.gatewayMAC,
            type: Ethernet.typeARP,
            payload: reply
        )
        let link = lock.withLock { $0.links[containerID] }
        link?.send(ethernet)
    }

    private func handleIPv4(_ packet: UnsafeRawBufferPointer, from containerID: String) {
        guard let header = IPv4Peek.tuple(packet) else { return }
        let action = lock.withLock { state -> IPv4Action in
            if header.dst == Self.address(NetworkGateway.gatewayAddress) {
                return .toGateway(state)
            }
            if let dst = state.peers[header.dst] {
                guard let src = state.peers[header.src], !src.networks.isDisjoint(with: dst.networks) else {
                    return .drop
                }
                return .sameNet(dst.link)
            }
            guard header.proto != Ethernet.protoICMP else { return .drop }
            guard state.allowsOutbound[header.src] == true,
                header.proto == Ethernet.protoTCP || header.proto == Ethernet.protoUDP,
                let forwarder = state.forwarder
            else { return .drop }
            return .outbound(forwarder)
        }
        switch action {
        case .drop:
            return
        case .sameNet(let link):
            link.sendIPv4(packet)
        case .outbound(let forwarder):
            forwarder.ingestIPv4(Data(packet))
        case .toGateway(let snap):
            handleToGateway(containerID: containerID, packet: packet, header: header, snapshot: snap)
        }
    }

    private func handleToGateway(
        containerID: String,
        packet: UnsafeRawBufferPointer,
        header: IPv4Peek.Tuple,
        snapshot: Snapshot
    ) {
        let copied = Data(packet)
        if header.proto == Ethernet.protoUDP, header.dstPort == 53,
           let parsed = IPv4Packet.parse(copied),
           let datagram = UDPDatagram.parse(parsed.payload)
        {
            handleDNS(containerID: containerID, packet: parsed, datagram: datagram, snapshot: snapshot)
            return
        }
        if header.proto == Ethernet.protoICMP, let parsed = IPv4Packet.parse(copied) {
            replyPing(containerID: containerID, packet: parsed, snapshot: snapshot)
            return
        }
        if snapshot.forwarder?.acceptIPv4(copied) == true {
            return
        }
        snapshot.writeUtun?(copied)
    }

    private func handleDNS(
        containerID: String,
        packet: IPv4Packet,
        datagram: UDPDatagram,
        snapshot: Snapshot
    ) {
        guard let question = GatewayDNS.parseQuery(datagram.payload) else { return }
        let local = lookup(name: question.name, from: packet.src, snapshot: snapshot)

        if question.type == GatewayDNS.typeA, let ip = local {
            replyDNS(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer(id: question.id, name: question.name, address: ip, type: question.type),
                snapshot: snapshot
            )
            return
        }
        if local != nil || question.type == GatewayDNS.typeAAAA {
            let nxdomain = local == nil && !question.name.contains(".")
            replyDNS(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer(
                    id: question.id,
                    name: question.name,
                    address: nil,
                    nxdomain: nxdomain,
                    type: question.type
                ),
                snapshot: snapshot
            )
            return
        }
        if allowsOutbound(src: Self.address(packet.src), snapshot: snapshot), question.name.contains(".") {
            snapshot.forwarder?.forwardDNS(
                query: datagram.payload,
                guestIP: packet.src,
                guestPort: datagram.srcPort,
                upstreams: GatewayDNS.upstreams(for: snapshot.dnsUpstreams[containerID] ?? [])
            )
            return
        }
        replyDNS(
            containerID: containerID,
            packet: packet,
            datagram: datagram,
            payload: GatewayDNS.answer(
                id: question.id,
                name: question.name,
                address: nil,
                nxdomain: true,
                type: question.type
            ),
            snapshot: snapshot
        )
    }

    private func replyDNS(
        containerID: String,
        packet: IPv4Packet,
        datagram: UDPDatagram,
        payload: Data,
        snapshot: Snapshot
    ) {
        let reply = UDPDatagram(srcPort: 53, dstPort: datagram.srcPort, payload: payload)
        let ip = IPv4Packet(
            tos: 0,
            id: nextID(),
            ttl: 64,
            proto: Ethernet.protoUDP,
            src: NetworkGateway.gatewayAddress,
            dst: packet.src,
            payload: reply.encode(src: NetworkGateway.gatewayAddress, dst: packet.src)
        )
        let encoded = ip.encode()
        encoded.withUnsafeBytes { snapshot.links[containerID]?.sendIPv4($0) }
    }

    private func replyPing(containerID: String, packet: IPv4Packet, snapshot: Snapshot) {
        guard packet.payload.count >= 8, packet.payload[0] == 8 else { return }
        var payload = packet.payload
        payload[0] = 0
        payload[2] = 0
        payload[3] = 0
        let sum = Ethernet.checksum(payload)
        payload[2] = UInt8(truncatingIfNeeded: sum >> 8)
        payload[3] = UInt8(truncatingIfNeeded: sum)
        let reply = IPv4Packet(
            tos: 0,
            id: nextID(),
            ttl: 64,
            proto: Ethernet.protoICMP,
            src: packet.dst,
            dst: packet.src,
            payload: payload
        )
        let encoded = reply.encode()
        encoded.withUnsafeBytes { snapshot.links[containerID]?.sendIPv4($0) }
    }

    private func deliver(_ packet: UnsafeRawBufferPointer, toIP ip: UInt32) {
        let link = lock.withLock { $0.peers[ip]?.link }
        link?.sendIPv4(packet)
    }

    private func allowsOutbound(src: UInt32, snapshot: Snapshot) -> Bool {
        snapshot.allowsOutbound[src] == true
    }

    private func lookup(name: String, from src: IPv4Address, snapshot: Snapshot) -> IPv4Address? {
        let needle = name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !needle.isEmpty else { return nil }
        let srcIP = Self.address(src)
        guard let owner = snapshot.records.first(where: { Self.address($0.ip) == srcIP })?.containerID,
            let visible = snapshot.networksOfContainer[owner]
        else { return nil }
        return match(needle, in: snapshot.records.filter { visible.contains($0.networkID) })
    }

    private func match(_ needle: String, in records: [NetworkGateway.Record]) -> IPv4Address? {
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

    private func nextID() -> UInt16 {
        ipID.withLock { value in
            value &+= 1
            return value
        }
    }

    private static func address(_ ip: IPv4Address) -> UInt32 {
        ip.bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
