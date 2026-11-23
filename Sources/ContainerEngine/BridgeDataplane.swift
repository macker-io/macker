import ContainerizationExtras
import Foundation
import os

/// Packet path for `bridge` virtio-net. Runs off ``NetworkGateway`` (an actor): RX comes
/// from ``FileHandleLink`` queues, TX from the SwiftTCP queue. The actor only publishes
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
        var peers6: [IPv6Key: Peer] = [:]
        var allowsOutbound: [UInt32: Bool] = [:]
        var allowsOutbound6: [IPv6Key: Bool] = [:]
        var networksOfContainer: [String: Set<String>] = [:]
        var gateways: Set<UInt32> = []
        var gateways6: Set<IPv6Key> = []
        var forwarder: (any GatewayForwarder)?
        var writeUtun: (@Sendable (Data) -> Void)?
    }

    private enum IPv4Action {
        case drop
        case sameNet(FileHandleLink)
        case outbound(any GatewayForwarder)
        case icmp(any GatewayForwarder)
        case toGateway(Snapshot)
    }

    private enum IPv6Action {
        case drop
        case sameNet(FileHandleLink)
        case outbound(any GatewayForwarder)
        case icmp(any GatewayForwarder)
        case toGateway(Snapshot)
        case ndp(Snapshot)
        case rs(Snapshot)
    }

    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())
    private let ipID = OSAllocatedUnfairLock<UInt16>(initialState: 1)

    func update(
        records: [NetworkGateway.Record],
        dnsUpstreams: [String: [String]],
        links: [String: FileHandleLink],
        forwarder: (any GatewayForwarder)?,
        gateways: Set<UInt32>,
        gateways6: Set<IPv6Key> = []
    ) {
        lock.withLock { state in
            state.records = records
            state.dnsUpstreams = dnsUpstreams
            state.links = links
            state.forwarder = forwarder
            state.gateways = gateways
            state.gateways6 = gateways6
            state.peers.removeAll(keepingCapacity: true)
            state.peers6.removeAll(keepingCapacity: true)
            state.allowsOutbound.removeAll(keepingCapacity: true)
            state.allowsOutbound6.removeAll(keepingCapacity: true)
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
                let netSet = networks[record.containerID] ?? []
                let allowed = outbound[record.containerID] == true
                let ip = record.ip.value
                state.peers[ip] = Peer(link: link, networks: netSet)
                state.allowsOutbound[ip] = allowed
                if let ip6 = record.ip6 {
                    let key6 = IPv6Key(ip6)
                    state.peers6[key6] = Peer(link: link, networks: netSet)
                    state.allowsOutbound6[key6] = allowed
                }
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
        case Ethernet.typeIPv6:
            guard let range = IPv6Peek.ipv6Range(inEthernet: frame) else { return }
            handleIPv6(UnsafeRawBufferPointer(rebasing: frame[range]), from: containerID)
        default:
            break
        }
    }

    func handleUtun(_ packet: UnsafeRawBufferPointer) {
        guard packet.count >= 1 else { return }
        switch packet[0] >> 4 {
        case 4:
            guard packet.count >= IPv4Packet.headerLength else { return }
            let ihl = Int(packet[0] & 0x0f) * 4
            let total = Int(packet[2]) << 8 | Int(packet[3])
            guard ihl >= IPv4Packet.headerLength, total >= ihl, packet.count >= total else { return }
            var prepared = Data(bytes: packet.baseAddress!, count: total)
            IPv4Peek.finishChecksums(&prepared)
            guard let header = IPv4Peek.tuple(prepared) else { return }
            prepared.withUnsafeBytes { deliver($0, toIP: header.dst) }
        case 6:
            guard packet.count >= IPv6Peek.headerLength else { return }
            let payloadLen = Int(packet[4]) << 8 | Int(packet[5])
            let total = IPv6Peek.headerLength + payloadLen
            guard packet.count >= total else { return }
            var prepared = Data(bytes: packet.baseAddress!, count: total)
            IPv6Peek.finishChecksums(&prepared)
            guard let header = IPv6Peek.tuple(prepared) else { return }
            deliver6(prepared, toIP: header.dst.address)
        default:
            break
        }
    }

    func deliver(_ packet: Data, toIP ip: IPv4Address) {
        packet.withUnsafeBytes { deliver($0, toIP: ip.value) }
    }

    func deliver6(_ packet: Data, toIP ip: IPv6Address) {
        let key = IPv6Key(ip)
        packet.withUnsafeBytes { bytes in
            let link = lock.withLock { $0.peers6[key]?.link }
            link?.sendIPv6(bytes)
        }
    }

    private func handleARP(containerID: String, frame: UnsafeRawBufferPointer) {
        guard let request = ARP.parseEthernetRequest(frame) else {
            return
        }
        let target = request.targetIP.value
        let known = lock.withLock { $0.gateways.contains(target) }
        guard known else { return }
        let reply = ARP.reply(
            senderMAC: NetworkGateway.gatewayMAC,
            senderIP: request.targetIP,
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

    /// IPv4 data requires an assigned source peer owned by the ingress container.
    static func allowsIPv4Source(ownerContainerID: String?, ingressContainerID: String) -> Bool {
        ownerContainerID == ingressContainerID
    }

    /// IPv6 data requires ingress ownership when the source is assigned.
    /// NS/RS may also use unassigned unspecified or link-local control sources.
    static func allowsIPv6Source(
        _ src: IPv6Key,
        ownerContainerID: String?,
        ingressContainerID: String,
        isControlSolicitation: Bool
    ) -> Bool {
        if let ownerContainerID {
            return ownerContainerID == ingressContainerID
        }
        guard isControlSolicitation else { return false }
        let isUnspecified = src.high == 0 && src.low == 0
        let isLinkLocal = (src.high & 0xFFC0_0000_0000_0000) == 0xFE80_0000_0000_0000
        return isUnspecified || isLinkLocal
    }

    private func handleIPv4(_ packet: UnsafeRawBufferPointer, from containerID: String) {
        guard let header = IPv4Peek.tuple(packet) else { return }
        let action = lock.withLock { state -> IPv4Action in
            guard let src = state.peers[header.src],
                Self.allowsIPv4Source(ownerContainerID: src.link.containerID, ingressContainerID: containerID)
            else {
                return .drop
            }
            if state.gateways.contains(header.dst) {
                return .toGateway(state)
            }
            if let dst = state.peers[header.dst] {
                guard !src.networks.isDisjoint(with: dst.networks) else {
                    return .drop
                }
                return .sameNet(dst.link)
            }
            guard state.allowsOutbound[header.src] == true, let forwarder = state.forwarder else {
                return .drop
            }
            if header.proto == Ethernet.protoICMP {
                return .icmp(forwarder)
            }
            guard header.proto == Ethernet.protoTCP || header.proto == Ethernet.protoUDP else {
                return .drop
            }
            return .outbound(forwarder)
        }
        switch action {
        case .drop:
            return
        case .sameNet(let link):
            link.sendIPv4(packet)
        case .outbound(let forwarder):
            forwarder.ingestIPv4(Data(packet))
        case .icmp(let forwarder):
            forwarder.handleICMP(Data(packet))
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
        if header.proto == Ethernet.protoICMP, let parsed = IPv4Packet.parse(copied),
            replyPing(containerID: containerID, packet: parsed, snapshot: snapshot)
        {
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
        if question.type == GatewayDNS.typeA, let ip = lookup(name: question.name, from: packet.src, snapshot: snapshot) {
            replyDNS(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer(id: question.id, name: question.name, address: ip, type: question.type),
                snapshot: snapshot
            )
            return
        }
        if question.type == GatewayDNS.typeAAAA, let ip6 = lookup6(name: question.name, from: packet.src, snapshot: snapshot) {
            replyDNS(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer6(id: question.id, name: question.name, address: ip6),
                snapshot: snapshot
            )
            return
        }
        let local4 = lookup(name: question.name, from: packet.src, snapshot: snapshot)
        let local6 = lookup6(name: question.name, from: packet.src, snapshot: snapshot)
        if local4 != nil || local6 != nil {
            replyDNS(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer(
                    id: question.id,
                    name: question.name,
                    address: nil,
                    nxdomain: false,
                    type: question.type
                ),
                snapshot: snapshot
            )
            return
        }
        if allowsOutbound(src: packet.src.value, snapshot: snapshot), question.name.contains(".") {
            snapshot.forwarder?.forwardDNS(
                query: datagram.payload,
                guestIP: packet.src,
                guestPort: datagram.srcPort,
                gatewayIP: packet.dst,
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
            src: packet.dst,
            dst: packet.src,
            payload: reply.encode(src: packet.dst, dst: packet.src)
        )
        let encoded = ip.encode()
        encoded.withUnsafeBytes { snapshot.links[containerID]?.sendIPv4($0) }
    }

    @discardableResult
    private func replyPing(containerID: String, packet: IPv4Packet, snapshot: Snapshot) -> Bool {
        guard packet.payload.count >= 8, packet.payload[0] == 8 else { return false }
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
        return true
    }

    private func deliver(_ packet: UnsafeRawBufferPointer, toIP ip: UInt32) {
        let link = lock.withLock { $0.peers[ip]?.link }
        link?.sendIPv4(packet)
    }

    private func allowsOutbound(src: UInt32, snapshot: Snapshot) -> Bool {
        snapshot.allowsOutbound[src] == true
    }

    private func lookup(name: String, from src: IPv4Address, snapshot: Snapshot) -> IPv4Address? {
        guard let owner = snapshot.records.first(where: { $0.ip.value == src.value })?.containerID,
            let visible = snapshot.networksOfContainer[owner]
        else { return nil }
        return GatewayDNS.lookup(
            name: name,
            records: snapshot.records,
            visibleNetworks: visible
        )
    }

    private func lookup6(name: String, from src: IPv4Address, snapshot: Snapshot) -> IPv6Address? {
        guard let owner = snapshot.records.first(where: { $0.ip.value == src.value })?.containerID,
            let visible = snapshot.networksOfContainer[owner]
        else { return nil }
        return GatewayDNS.lookup6(
            name: name,
            records: snapshot.records,
            visibleNetworks: visible
        )
    }

    private func handleIPv6(_ packet: UnsafeRawBufferPointer, from containerID: String) {
        guard let header = IPv6Peek.tuple(packet) else { return }
        let isNS = header.nextHeader == Ethernet.protoICMPv6
            && packet.count >= IPv6Peek.headerLength + 24
            && packet[IPv6Peek.headerLength] == NDP.typeNeighborSolicitation
        let isRS = header.nextHeader == Ethernet.protoICMPv6
            && packet.count >= IPv6Peek.headerLength + 8
            && packet[IPv6Peek.headerLength] == NDP.typeRouterSolicitation
        let action = lock.withLock { state -> IPv6Action in
            let srcPeer = state.peers6[header.src]
            guard Self.allowsIPv6Source(
                header.src,
                ownerContainerID: srcPeer?.link.containerID,
                ingressContainerID: containerID,
                isControlSolicitation: isNS || isRS
            ) else {
                return .drop
            }
            if isNS {
                return .ndp(state)
            }
            if isRS {
                return .rs(state)
            }
            guard let src = srcPeer else {
                return .drop
            }
            if state.gateways6.contains(header.dst) {
                return .toGateway(state)
            }
            if let dst = state.peers6[header.dst] {
                guard !src.networks.isDisjoint(with: dst.networks) else {
                    return .drop
                }
                return .sameNet(dst.link)
            }
            guard state.allowsOutbound6[header.src] == true, let forwarder = state.forwarder else {
                return .drop
            }
            if header.nextHeader == Ethernet.protoICMPv6 {
                return .icmp(forwarder)
            }
            guard header.nextHeader == Ethernet.protoTCP || header.nextHeader == Ethernet.protoUDP else {
                return .drop
            }
            return .outbound(forwarder)
        }
        switch action {
        case .drop:
            return
        case .sameNet(let link):
            link.sendIPv6(packet)
        case .outbound(let forwarder):
            forwarder.ingestIPv6(Data(packet))
        case .icmp(let forwarder):
            forwarder.handleICMPv6(Data(packet))
        case .ndp(let snap):
            handleNDP(containerID: containerID, packet: Data(packet), snapshot: snap)
        case .rs(let snap):
            handleRS(containerID: containerID, packet: Data(packet), snapshot: snap)
        case .toGateway(let snap):
            handleToGateway6(containerID: containerID, packet: packet, header: header, snapshot: snap)
        }
    }

    private func handleRS(containerID: String, packet: Data, snapshot: Snapshot) {
        guard let parsed = IPv6Packet.parse(packet),
            let record = snapshot.records.first(where: { $0.containerID == containerID && $0.gateway6 != nil }),
            let gw6 = record.gateway6
        else { return }
        let prefix = IPv6Address(gw6.value & 0xFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0000)
        let ra = NDP.routerAdvertisement(
            src: gw6,
            dst: parsed.src,
            prefix: prefix,
            prefixLength: 64,
            mtu: UInt32(FileHandleLink.virtioMTU),
            mac: NetworkGateway.gatewayMAC
        )
        ra.withUnsafeBytes { snapshot.links[containerID]?.sendIPv6($0) }
    }

    private func handleNDP(containerID: String, packet: Data, snapshot: Snapshot) {
        guard let parsed = IPv6Packet.parse(packet),
            let target = NDP.parseNeighborSolicitation(parsed)
        else { return }
        let targetKey = IPv6Key(target)
        let known = snapshot.gateways6.contains(targetKey) || snapshot.peers6[targetKey] != nil
        guard known else { return }
        let na = NDP.neighborAdvertisement(
            src: target,
            dst: parsed.src,
            target: target,
            mac: NetworkGateway.gatewayMAC
        )
        na.withUnsafeBytes { snapshot.links[containerID]?.sendIPv6($0) }
    }

    private func handleToGateway6(
        containerID: String,
        packet: UnsafeRawBufferPointer,
        header: IPv6Peek.Tuple,
        snapshot: Snapshot
    ) {
        let copied = Data(packet)
        if header.nextHeader == Ethernet.protoUDP, header.dstPort == 53,
            let parsed = IPv6Packet.parse(copied),
            let datagram = UDPDatagram.parse(parsed.payload)
        {
            handleDNS6(containerID: containerID, packet: parsed, datagram: datagram, snapshot: snapshot)
            return
        }
        if header.nextHeader == Ethernet.protoICMPv6,
            let parsed = IPv6Packet.parse(copied),
            replyPing6(containerID: containerID, packet: parsed, snapshot: snapshot)
        {
            return
        }
        snapshot.writeUtun?(copied)
    }

    private func handleDNS6(
        containerID: String,
        packet: IPv6Packet,
        datagram: UDPDatagram,
        snapshot: Snapshot
    ) {
        guard let question = GatewayDNS.parseQuery(datagram.payload) else { return }
        let owner = snapshot.records.first(where: { $0.ip6.map(IPv6Key.init) == IPv6Key(packet.src) })?.containerID
        let visible = owner.flatMap { snapshot.networksOfContainer[$0] } ?? []
        if question.type == GatewayDNS.typeAAAA,
            let ip6 = GatewayDNS.lookup6(name: question.name, records: snapshot.records, visibleNetworks: visible)
        {
            replyDNS6(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer6(id: question.id, name: question.name, address: ip6),
                snapshot: snapshot
            )
            return
        }
        if question.type == GatewayDNS.typeA,
            let ip = GatewayDNS.lookup(name: question.name, records: snapshot.records, visibleNetworks: visible)
        {
            replyDNS6(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer(id: question.id, name: question.name, address: ip, type: question.type),
                snapshot: snapshot
            )
            return
        }
        if snapshot.allowsOutbound6[IPv6Key(packet.src)] == true, question.name.contains(".") {
            snapshot.forwarder?.forwardDNS6(
                query: datagram.payload,
                guestIP: packet.src,
                guestPort: datagram.srcPort,
                gatewayIP: packet.dst,
                upstreams: GatewayDNS.upstreams(for: snapshot.dnsUpstreams[containerID] ?? [])
            )
            return
        }
        replyDNS6(
            containerID: containerID,
            packet: packet,
            datagram: datagram,
            payload: GatewayDNS.answer6(id: question.id, name: question.name, address: nil, nxdomain: true),
            snapshot: snapshot
        )
    }

    private func replyDNS6(
        containerID: String,
        packet: IPv6Packet,
        datagram: UDPDatagram,
        payload: Data,
        snapshot: Snapshot
    ) {
        let reply = UDPDatagram(srcPort: 53, dstPort: datagram.srcPort, payload: payload)
        let ip = IPv6Packet(
            hopLimit: 64,
            nextHeader: Ethernet.protoUDP,
            src: packet.dst,
            dst: packet.src,
            payload: reply.encode(src: packet.dst, dst: packet.src)
        )
        let encoded = ip.encode()
        encoded.withUnsafeBytes { snapshot.links[containerID]?.sendIPv6($0) }
    }

    @discardableResult
    private func replyPing6(containerID: String, packet: IPv6Packet, snapshot: Snapshot) -> Bool {
        guard packet.payload.count >= 8, packet.payload[0] == 128 else { return false }
        var payload = packet.payload
        payload[0] = 129
        payload[2] = 0
        payload[3] = 0
        let sum = IPv6Packet.pseudoChecksum(
            src: packet.dst,
            dst: packet.src,
            nextHeader: Ethernet.protoICMPv6,
            payload: payload
        )
        payload[2] = UInt8(truncatingIfNeeded: sum >> 8)
        payload[3] = UInt8(truncatingIfNeeded: sum)
        let reply = IPv6Packet(
            hopLimit: 64,
            nextHeader: Ethernet.protoICMPv6,
            src: packet.dst,
            dst: packet.src,
            payload: payload
        )
        let encoded = reply.encode()
        encoded.withUnsafeBytes { snapshot.links[containerID]?.sendIPv6($0) }
        return true
    }

    private func nextID() -> UInt16 {
        ipID.withLock { value in
            value &+= 1
            return value
        }
    }

}
