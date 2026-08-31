import ContainerizationExtras
import Foundation
import os
@testable import ContainerEngine

/// Minimal guest TCP peer used by SwiftTCP gateway tests and resource benches.
final class GuestTCPSession: @unchecked Sendable {
    let guest: IPv4Address
    let remote: IPv4Address
    let hostPort: UInt16
    let srcPort: UInt16 = 41_000
    let isn: UInt32 = 1_000
    var forwarder: (any GatewayForwarder)?
    private let packets = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private let packetSignal = DispatchSemaphore(value: 0)
    private var sndNxt: UInt32
    private var rcvNxt: UInt32 = 0
    private var peerWindow: UInt32 = 65_535
    private var sndUna: UInt32
    private var ipID: UInt16 = 1
    private var sndWndScale: UInt32 = 0

    init(guest: IPv4Address, remote: IPv4Address, hostPort: UInt16) {
        self.guest = guest
        self.remote = remote
        self.hostPort = hostPort
        self.sndNxt = isn
        self.sndUna = isn
    }

    func notePacket(_ data: Data) {
        packets.withLock { $0.append(data) }
        packetSignal.signal()
    }

    func handshake() throws {
        sendSegment(
            seq: isn, ack: 0, flags: TCPSegment.Flags.syn.rawValue,
            options: Data([0x02, 0x04, 0x10, 0x00, 0x01, 0x03, 0x03, 0x07])
        )
        sndNxt &+= 1
        sndUna &+= 1
        let deadline = Date().addingTimeInterval(3)
        var established = false
        while Date() < deadline, !established {
            for item in drainPackets(timeout: 0.05) where item.flags.contains(.syn) {
                rcvNxt = item.seq &+ 1
                if let scale = tcpWindowScale(item.tcp) {
                    sndWndScale = UInt32(scale)
                }
                peerWindow = UInt32(item.window) << sndWndScale
                sendSegment(seq: sndNxt, ack: rcvNxt, flags: TCPSegment.Flags.ack.rawValue)
                established = true
            }
        }
        guard established else {
            throw EngineError.conflict("guest TCP handshake timed out")
        }
    }

    func transfer(
        bytes total: Int,
        hostSends: Bool,
        hostReceived: OSAllocatedUnfairLock<Int>,
        hostDone: DispatchSemaphore,
        deadlineSeconds: TimeInterval = 15
    ) -> Int {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        let mss = 4096
        var received = 0
        var payloadSent = 0

        func pumpGuestPayload() {
            guard !hostSends else { return }
            while payloadSent < total {
                let inFlight = Int(sndNxt &- sndUna)
                let room = max(0, Int(peerWindow) - inFlight)
                let chunk = min(mss, total - payloadSent, room)
                if chunk <= 0 { break }
                sendSegment(
                    seq: sndNxt, ack: rcvNxt,
                    flags: TCPSegment.Flags.pushAck.rawValue,
                    payload: Data(count: chunk)
                )
                sndNxt &+= UInt32(chunk)
                payloadSent += chunk
            }
        }

        pumpGuestPayload()
        while Date() < deadline {
            if hostSends, received >= total { break }
            if !hostSends, hostReceived.withLock({ $0 }) >= total { break }
            let inFlight = Int(sndNxt &- sndUna)
            let canSend = !hostSends && payloadSent < total && Int(peerWindow) > inFlight
            for item in drainPackets(timeout: canSend ? 0 : 0.002) {
                if item.flags.contains(.rst) { break }
                if item.flags.contains(.ack) {
                    if item.ack &- sndUna < 0x8000_0000 { sndUna = item.ack }
                    peerWindow = UInt32(item.window) << sndWndScale
                }
                if !item.payload.isEmpty {
                    if hostSends, item.seq == rcvNxt, received < total {
                        received += min(item.payload.count, total - received)
                        rcvNxt &+= UInt32(item.payload.count)
                    }
                    sendSegment(seq: sndNxt, ack: rcvNxt, flags: TCPSegment.Flags.ack.rawValue)
                }
                if item.flags.contains(.fin) {
                    rcvNxt = item.seq &+ 1
                    sendSegment(seq: sndNxt, ack: rcvNxt, flags: TCPSegment.Flags.ack.rawValue)
                }
            }
            pumpGuestPayload()
        }
        if !hostSends {
            _ = hostDone.wait(timeout: .now() + 2)
        }
        return hostSends ? received : hostReceived.withLock { $0 }
    }

    private struct SegmentView {
        var flags: TCPSegment.Flags
        var seq: UInt32
        var ack: UInt32
        var window: UInt16
        var payload: Data
        var tcp: Data
    }

    private func drainPackets(timeout: TimeInterval) -> [SegmentView] {
        if packets.withLock({ $0.isEmpty }), timeout > 0 {
            _ = packetSignal.wait(timeout: .now() + timeout)
        }
        let batch = packets.withLock { value -> [Data] in
            let copy = value
            value.removeAll(keepingCapacity: true)
            return copy
        }
        return batch.compactMap { ip -> SegmentView? in
            guard let packet = IPv4Packet.parse(ip), let segment = TCPSegment.parse(packet.payload) else {
                return nil
            }
            return SegmentView(
                flags: segment.flags, seq: segment.seq, ack: segment.ack,
                window: segment.window, payload: segment.payload, tcp: packet.payload
            )
        }
    }

    private func sendSegment(
        seq: UInt32, ack: UInt32, flags: UInt8,
        options: Data = Data(), payload: Data = Data()
    ) {
        let tcp = makeTCPPacket(
            src: guest, dst: remote, srcPort: srcPort, dstPort: hostPort,
            seq: seq, ack: ack, flags: flags, options: options, payload: payload
        )
        let packet = IPv4Packet(
            tos: 0, id: ipID, ttl: 64, proto: Ethernet.protoTCP,
            src: guest, dst: remote, payload: tcp
        )
        ipID &+= 1
        guard let segment = TCPSegment.parse(tcp), let forwarder else { return }
        forwarder.handleTCP(packet: packet, segment: segment)
    }
}

func tcpWindowScale(_ tcp: Data) -> UInt8? {
    guard tcp.count >= 20 else { return nil }
    let header = Int(tcp[12] >> 4) * 4
    var index = 20
    while index + 2 < min(header, tcp.count) {
        switch tcp[index] {
        case 0:
            return nil
        case 1:
            index += 1
        case 3:
            if tcp[index + 1] == 3 { return tcp[index + 2] }
            index += max(Int(tcp[index + 1]), 2)
        default:
            index += max(Int(tcp[index + 1]), 2)
        }
    }
    return nil
}

func makeTCPPacket(
    src: IPv4Address, dst: IPv4Address, srcPort: UInt16,
    dstPort: UInt16, seq: UInt32, ack: UInt32 = 0,
    flags: UInt8, options: Data = Data(), payload: Data = Data()
) -> Data {
    var header = Data(count: TCPSegment.headerLength)
    header[0] = UInt8(truncatingIfNeeded: srcPort >> 8)
    header[1] = UInt8(truncatingIfNeeded: srcPort)
    header[2] = UInt8(truncatingIfNeeded: dstPort >> 8)
    header[3] = UInt8(truncatingIfNeeded: dstPort)
    header[4] = UInt8(truncatingIfNeeded: seq >> 24)
    header[5] = UInt8(truncatingIfNeeded: seq >> 16)
    header[6] = UInt8(truncatingIfNeeded: seq >> 8)
    header[7] = UInt8(truncatingIfNeeded: seq)
    header[8] = UInt8(truncatingIfNeeded: ack >> 24)
    header[9] = UInt8(truncatingIfNeeded: ack >> 16)
    header[10] = UInt8(truncatingIfNeeded: ack >> 8)
    header[11] = UInt8(truncatingIfNeeded: ack)
    let offset = TCPSegment.headerLength + options.count
    header[12] = UInt8((offset / 4) << 4)
    header[13] = flags
    header[14] = 0xff
    header[15] = 0xff
    let transport = header + options + payload
    var pseudo = Data()
    pseudo.append(contentsOf: src.bytes)
    pseudo.append(contentsOf: dst.bytes)
    pseudo.append(0)
    pseudo.append(Ethernet.protoTCP)
    pseudo.append(UInt8(truncatingIfNeeded: transport.count >> 8))
    pseudo.append(UInt8(truncatingIfNeeded: transport.count))
    let sum = Ethernet.checksum(pseudo + transport)
    header[16] = UInt8(truncatingIfNeeded: sum >> 8)
    header[17] = UInt8(truncatingIfNeeded: sum)
    return header + options + payload
}
