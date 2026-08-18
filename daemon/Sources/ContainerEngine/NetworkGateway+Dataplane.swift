import ContainerizationExtras
import Foundation

/// L3 dataplane: what the gateway does with each guest frame.
///
/// Container-to-container, ARP, ICMP and DNS are answered here and stay here regardless of
/// how off-link traffic is carried. Everything else is handed to ``GatewayForwarder``.
extension NetworkGateway {
    func handleFrame(containerID: String, frame: Data) {
        guard let parsed = Ethernet.parse(frame) else { return }
        switch parsed.type {
        case Ethernet.typeARP:
            handleARP(containerID: containerID, srcMAC: parsed.src, payload: parsed.payload)
        case Ethernet.typeIPv4:
            handleIPv4(packet: parsed.payload, from: containerID)
        default:
            break
        }
    }

    /// The gateway address is the only ARP target we answer; the link is point-to-point.
    private func handleARP(containerID: String, srcMAC: MACAddress, payload: Data) {
        guard let request = ARP.parseRequest(payload), request.targetIP == Self.gatewayAddress else { return }
        let reply = ARP.reply(
            senderMAC: Self.gatewayMAC,
            senderIP: Self.gatewayAddress,
            targetMAC: srcMAC,
            targetIP: request.senderIP
        )
        let frame = Ethernet.frame(dst: srcMAC, src: Self.gatewayMAC, type: Ethernet.typeARP, payload: reply)
        links[containerID]?.send(frame)
    }

    private func handleIPv4(packet data: Data, from containerID: String) {
        guard let packet = IPv4Packet.parse(data) else { return }

        if packet.dst == Self.gatewayAddress {
            handleToGateway(containerID: containerID, packet: packet)
            return
        }

        // Same-network peer: pure L3 forward, no NAT, no TCP state.
        if let peer = records.first(where: { $0.ip == packet.dst }) {
            guard canForward(src: packet.src, dst: packet.dst) else { return }
            deliver(packet.encode(), to: peer.containerID)
            return
        }

        // Outbound ICMP would need a raw socket (root); ping to the internet is not supported.
        guard packet.proto != Ethernet.protoICMP else { return }
        guard allowsOutbound(src: packet.src) else { return }

        switch packet.proto {
        case Ethernet.protoUDP:
            if let datagram = UDPDatagram.parse(packet.payload) {
                forwarder?.handleUDP(packet: packet, datagram: datagram)
            }
        case Ethernet.protoTCP:
            if let segment = TCPSegment.parse(packet.payload) {
                forwarder?.handleTCP(packet: packet, segment: segment)
            }
        default:
            break
        }
    }

    private func handleToGateway(containerID: String, packet: IPv4Packet) {
        if packet.proto == Ethernet.protoUDP,
            let datagram = UDPDatagram.parse(packet.payload),
            datagram.dstPort == 53
        {
            handleDNS(containerID: containerID, packet: packet, datagram: datagram)
            return
        }
        if packet.proto == Ethernet.protoICMP {
            replyPing(containerID: containerID, packet: packet)
            return
        }
        // A reply on a published-port flow, otherwise traffic aimed at the Mac itself.
        if forwarder?.acceptFromGuest(packet) == true {
            return
        }
        writeToUtun(packet.encode())
    }

    private func handleDNS(containerID: String, packet: IPv4Packet, datagram: UDPDatagram) {
        guard let question = GatewayDNS.parseQuery(datagram.payload) else { return }
        let local = lookup(name: question.name, from: packet.src)

        if question.type == GatewayDNS.typeA, let ip = local {
            replyDNS(
                containerID: containerID,
                packet: packet,
                datagram: datagram,
                payload: GatewayDNS.answer(id: question.id, name: question.name, address: ip, type: question.type)
            )
            return
        }
        if local != nil || question.type == GatewayDNS.typeAAAA {
            // Local names: AAAA is NODATA (musl treats NXDOMAIN as "no such host").
            // Other AAAA: the dataplane is IPv4-only, so do not recurse — glibc otherwise
            // waits through its resolver timeout (~20s) when the reply QTYPE does not match.
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
                )
            )
            return
        }
        // `--internal` containers get no upstream recursion, only NXDOMAIN.
        if allowsOutbound(src: packet.src), question.name.contains(".") {
            forwarder?.forwardDNS(query: datagram.payload, guestIP: packet.src, guestPort: datagram.srcPort)
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
            )
        )
    }

    private func replyDNS(containerID: String, packet: IPv4Packet, datagram: UDPDatagram, payload: Data) {
        let reply = UDPDatagram(srcPort: 53, dstPort: datagram.srcPort, payload: payload)
        let ip = IPv4Packet(
            tos: 0,
            id: nextID(),
            ttl: 64,
            proto: Ethernet.protoUDP,
            src: Self.gatewayAddress,
            dst: packet.src,
            payload: reply.encode(src: Self.gatewayAddress, dst: packet.src)
        )
        deliver(ip.encode(), to: containerID)
    }

    /// Echo reply for `ping <gateway>`, so the guest can prove the link is up.
    private func replyPing(containerID: String, packet: IPv4Packet) {
        guard packet.payload.count >= 8, packet.payload[0] == 8 else { return }
        var payload = packet.payload
        payload[0] = 0 // echo reply
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
        deliver(reply.encode(), to: containerID)
    }

    /// Mac → container, once a utun route exists.
    func handleUtun(_ packet: Data) {
        guard let parsed = IPv4Packet.parse(packet) else { return }
        deliver(packet, toIP: parsed.dst)
    }

    func deliver(_ packet: Data, toIP ip: IPv4Address) {
        guard let record = records.first(where: { $0.ip == ip }) else { return }
        deliver(packet, to: record.containerID)
    }

    private func deliver(_ packet: Data, to containerID: String) {
        guard let link = links[containerID] else { return }
        let frame = Ethernet.frame(
            dst: link.guestMAC,
            src: Self.gatewayMAC,
            type: Ethernet.typeIPv4,
            payload: packet
        )
        link.send(frame)
    }
}
