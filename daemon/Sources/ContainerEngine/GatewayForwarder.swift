import ContainerizationExtras
import Foundation

/// How traffic that is *not* container-to-container leaves and enters the gateway.
///
/// ``GatewayNAT`` implements this by terminating TCP/UDP in the daemon and reopening
/// the flow with `NWConnection`. That is a consequence of virtio frames only reaching
/// user space: without a route on the Mac, the daemon has to act as the peer.
///
/// A kernel implementation (privileged utun + `pf` NAT/redirect) can conform instead
/// and forward IP without touching TCP state. Same-network forwarding, ARP, ICMP and
/// DNS stay in ``NetworkGateway`` either way, so swapping this out does not affect
/// IPAM, `network connect`, or the guest's single `eth0`.
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

    /// Drop every flow and listener.
    func closeAll()
}
