import ContainerizationExtras
import Foundation

/// How traffic that is *not* container-to-container leaves and enters the gateway.
///
/// ``GatewayLwIP`` terminates guest TCP/UDP with a complete userspace protocol stack and
/// reopens only the application payload on Mac sockets. Same-network forwarding, ARP, ICMP and
/// DNS stay in ``NetworkGateway``, so this does not affect IPAM, `network connect`, or the
/// guest's single `eth0`.
protocol GatewayForwarder: Sendable {
    /// Guest → outside, per datagram.
    func handleUDP(packet: IPv4Packet, datagram: UDPDatagram)

    /// Guest → outside, per segment. Implementations own the flow state.
    func handleTCP(packet: IPv4Packet, segment: TCPSegment)

    /// Recurse a guest DNS query upstream and answer from the gateway address.
    func forwardDNS(query: Data, guestIP: IPv4Address, guestPort: UInt16)

    /// Guest reply that belongs to an inbound (published-port) flow.
    /// Returns false when the packet is not ours, so the caller can route it elsewhere.
    func acceptFromGuest(_ packet: IPv4Packet) -> Bool

    /// Listen on a Mac port and relay it to `guestIP:guestPort`. Used by `-p`.
    /// Returns the bound port.
    func listenLocal(guestIP: IPv4Address, guestPort: UInt16, udp: Bool) async throws -> Int

    /// Drop the `-p` relay started by ``listenLocal(guestIP:guestPort:udp:)`` and its inbound flows.
    func stopListenLocal(guestIP: IPv4Address, guestPort: UInt16, udp: Bool)

    /// Drop every flow and listener.
    func closeAll()
}
