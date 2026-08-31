import ContainerizationExtras
import Foundation

/// How traffic that is *not* container-to-container leaves and enters the gateway.
///
/// ``GatewaySwiftTCP`` terminates guest TCP/UDP with the SwiftTCP userspace stack and
/// reopens only the application payload on Mac sockets. Same-network forwarding, ARP,
/// gateway ICMP echo, and embedded DNS stay in ``BridgeDataplane``. This does not affect
/// IPAM, `network connect`, or the guest's single `eth0`.
protocol GatewayForwarder: Sendable {
    /// IPv4 datagram from virtio (no Ethernet). Established flows skip Swift TCP/UDP parse.
    func ingestIPv4(_ packet: Data)

    /// Guest → outside ICMP (echo). Other ICMP types may be ignored.
    func handleICMP(_ packet: Data)

    /// Published-port reply aimed at the gateway. `true` if the packet was consumed.
    func acceptIPv4(_ packet: Data) -> Bool

    /// Recurse a guest DNS query upstream and answer from `gatewayIP`.
    /// `upstreams` is already resolved (`GatewayDNS.upstreams(for:)`); the first reachable server is used.
    func forwardDNS(
        query: Data,
        guestIP: IPv4Address,
        guestPort: UInt16,
        gatewayIP: IPv4Address,
        upstreams: [String]
    )

    /// Listen on a Mac port and relay it to `guestIP:guestPort`. Used by `-p`.
    /// `gatewayIP` is the per-network next hop the guest already uses (SYN source).
    /// Returns the bound port.
    func listenLocal(
        guestIP: IPv4Address,
        guestPort: UInt16,
        udp: Bool,
        gatewayIP: IPv4Address
    ) async throws -> Int

    /// Drop the `-p` relay started by ``listenLocal(guestIP:guestPort:udp:)`` and its inbound flows.
    func stopListenLocal(guestIP: IPv4Address, guestPort: UInt16, udp: Bool)

    /// Drop every flow and listener.
    func closeAll()
}

extension GatewayForwarder {
    /// Tests and callers that already parsed L4 still enter through ``ingestIPv4``.
    func handleUDP(packet: IPv4Packet, datagram: UDPDatagram) {
        _ = datagram
        ingestIPv4(packet.encode())
    }

    func handleTCP(packet: IPv4Packet, segment: TCPSegment) {
        _ = segment
        ingestIPv4(packet.encode())
    }
}
