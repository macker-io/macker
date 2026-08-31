import ContainerizationExtras
import Darwin
import Foundation
import os

/// Relays guest ICMP echo through a Mac `IPPROTO_ICMP` datagram socket.
final class GatewayICMP: @unchecked Sendable {
    private struct EchoKey: Hashable {
        var dst: UInt32
        var ident: UInt16
        var seq: UInt16
    }

    private struct State {
        var fd: Int32 = -1
        var echoes: [EchoKey: IPv4Address] = [:]
    }

    private static let maxEchoes = 4_096

    private let onGuest: @Sendable (IPv4Address, Data) -> Void
    private let queue = DispatchQueue(label: "io.macker.net.icmp")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private var source: DispatchSourceRead?

    init(onGuest: @escaping @Sendable (IPv4Address, Data) -> Void) {
        self.onGuest = onGuest
        let opened = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard opened >= 0 else { return }
        let flags = fcntl(opened, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(opened, F_SETFL, flags | O_NONBLOCK)
        }
        lock.withLock { $0.fd = opened }
        let source = DispatchSource.makeReadSource(fileDescriptor: opened, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        self.source = source
        source.resume()
    }

    func ingest(_ packet: Data) {
        guard let parsed = IPv4Packet.parse(packet),
            parsed.proto == Ethernet.protoICMP,
            parsed.payload.count >= 8,
            parsed.payload[0] == 8
        else { return }
        let ident = UInt16(parsed.payload[4]) << 8 | UInt16(parsed.payload[5])
        let seq = UInt16(parsed.payload[6]) << 8 | UInt16(parsed.payload[7])
        let key = EchoKey(dst: parsed.dst.value, ident: ident, seq: seq)
        let fd = lock.withLock { state -> Int32 in
            guard state.fd >= 0, state.echoes.count < Self.maxEchoes else { return -1 }
            state.echoes[key] = parsed.src
            return state.fd
        }
        guard fd >= 0 else { return }
        queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
            self?.lock.withLock { _ = $0.echoes.removeValue(forKey: key) }
        }
        parsed.payload.withUnsafeBytes { raw in
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = parsed.dst.value.bigEndian
            _ = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, raw.baseAddress, parsed.payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        source?.cancel()
        source = nil
        let fd = lock.withLock { state -> Int32 in
            let fd = state.fd
            state.fd = -1
            state.echoes.removeAll()
            return fd
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    deinit {
        close()
    }

    private func drain() {
        let fd = lock.withLock { $0.fd }
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(fd, base, raw.count, 0, $0, &addrLen)
                    }
                }
            }
            if received < 8 { return }
            var icmpAt = 0
            var replySrc = UInt32(bigEndian: addr.sin_addr.s_addr)
            if buffer[0] >> 4 == 4 {
                let ihl = Int(buffer[0] & 0x0f) * 4
                guard received >= ihl + 8 else { continue }
                icmpAt = ihl
                replySrc = UInt32(buffer[12]) << 24 | UInt32(buffer[13]) << 16
                    | UInt32(buffer[14]) << 8 | UInt32(buffer[15])
            }
            guard buffer[icmpAt] == 0 else { continue }
            let ident = UInt16(buffer[icmpAt + 4]) << 8 | UInt16(buffer[icmpAt + 5])
            let seq = UInt16(buffer[icmpAt + 6]) << 8 | UInt16(buffer[icmpAt + 7])
            let key = EchoKey(dst: replySrc, ident: ident, seq: seq)
            guard let guest = lock.withLock({ $0.echoes.removeValue(forKey: key) }) else { continue }
            let payload = Data(buffer[icmpAt..<received])
            let packet = IPv4Packet(
                tos: 0,
                id: 0,
                ttl: 64,
                proto: Ethernet.protoICMP,
                src: IPv4Address(replySrc),
                dst: guest,
                payload: payload
            )
            onGuest(guest, packet.encode())
        }
    }
}
