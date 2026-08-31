import ContainerizationExtras
import Foundation

/// Wire-header peeks that do not copy the frame into `[UInt8]` / re-`encode()`.
enum IPv4Peek {
    struct Tuple {
        var src: UInt32
        var dst: UInt32
        var proto: UInt8
        var srcPort: UInt16
        var dstPort: UInt16
        var tcpFlags: UInt8
    }

    static func ethernetType(_ frame: Data) -> UInt16? {
        frame.withUnsafeBytes { ethernetType($0) }
    }

    static func ethernetType(_ bytes: UnsafeRawBufferPointer) -> UInt16? {
        guard bytes.count >= Ethernet.headerLength else { return nil }
        return UInt16(bytes[12]) << 8 | UInt16(bytes[13])
    }

    static func ipv4Range(inEthernet bytes: UnsafeRawBufferPointer) -> Range<Int>? {
        guard bytes.count >= Ethernet.headerLength + IPv4Packet.headerLength else { return nil }
        let start = Ethernet.headerLength
        let versionIhl = bytes[start]
        let ihl = Int(versionIhl & 0x0f) * 4
        guard versionIhl >> 4 == 4, ihl >= IPv4Packet.headerLength else { return nil }
        let total = Int(bytes[start + 2]) << 8 | Int(bytes[start + 3])
        guard total >= ihl, bytes.count >= start + total else { return nil }
        return start..<(start + total)
    }

    static func ipv4Datagram(fromEthernet frame: Data) -> Data? {
        frame.withUnsafeBytes { bytes in
            guard let range = ipv4Range(inEthernet: bytes) else { return nil }
            return Data(bytes[range])
        }
    }

    static func tuple(_ packet: Data) -> Tuple? {
        packet.withUnsafeBytes { tuple($0) }
    }

    static func tuple(_ bytes: UnsafeRawBufferPointer) -> Tuple? {
        guard bytes.count >= IPv4Packet.headerLength else { return nil }
        let versionIhl = bytes[0]
        let ihl = Int(versionIhl & 0x0f) * 4
        guard versionIhl >> 4 == 4, ihl >= IPv4Packet.headerLength, bytes.count >= ihl else { return nil }
        let total = Int(bytes[2]) << 8 | Int(bytes[3])
        guard total >= ihl, bytes.count >= total else { return nil }
        let proto = bytes[9]
        var srcPort: UInt16 = 0
        var dstPort: UInt16 = 0
        var tcpFlags: UInt8 = 0
        if proto == Ethernet.protoTCP || proto == Ethernet.protoUDP {
            guard bytes.count >= ihl + 4 else { return nil }
            srcPort = UInt16(bytes[ihl]) << 8 | UInt16(bytes[ihl + 1])
            dstPort = UInt16(bytes[ihl + 2]) << 8 | UInt16(bytes[ihl + 3])
        }
        if proto == Ethernet.protoTCP {
            guard bytes.count >= ihl + 14 else { return nil }
            tcpFlags = bytes[ihl + 13]
        }
        return Tuple(
            src: read32(bytes, 12),
            dst: read32(bytes, 16),
            proto: proto,
            srcPort: srcPort,
            dstPort: dstPort,
            tcpFlags: tcpFlags
        )
    }

    /// Fill IPv4 and transport checksums in place. utun packets from the Mac kernel
    /// often have zero checksums (TX offload); virtio delivers them as CHECKSUM_NONE.
    static func finishChecksums(_ packet: inout Data) {
        packet.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count >= IPv4Packet.headerLength else { return }
            let ihl = Int(raw[0] & 0x0f) * 4
            guard raw[0] >> 4 == 4, ihl >= IPv4Packet.headerLength, raw.count >= ihl else { return }
            let total = min(Int(raw[2]) << 8 | Int(raw[3]), raw.count)
            guard total >= ihl else { return }
            if raw[10] == 0, raw[11] == 0 {
                let headerSum = Ethernet.checksum(UnsafeRawBufferPointer(start: base, count: ihl))
                raw[10] = UInt8(truncatingIfNeeded: headerSum >> 8)
                raw[11] = UInt8(truncatingIfNeeded: headerSum)
            }
            let payloadLen = total - ihl
            let proto = raw[9]
            switch proto {
            case Ethernet.protoICMP:
                guard payloadLen >= 8, raw[ihl + 2] == 0, raw[ihl + 3] == 0 else { return }
                let sum = Ethernet.checksum(UnsafeRawBufferPointer(start: base + ihl, count: payloadLen))
                raw[ihl + 2] = UInt8(truncatingIfNeeded: sum >> 8)
                raw[ihl + 3] = UInt8(truncatingIfNeeded: sum)
            case Ethernet.protoTCP:
                guard payloadLen >= 20, raw[ihl + 16] == 0, raw[ihl + 17] == 0 else { return }
                let sum = transportChecksum(base: base, ihl: ihl, proto: proto, payloadLen: payloadLen)
                raw[ihl + 16] = UInt8(truncatingIfNeeded: sum >> 8)
                raw[ihl + 17] = UInt8(truncatingIfNeeded: sum)
            case Ethernet.protoUDP:
                guard payloadLen >= 8, raw[ihl + 6] == 0, raw[ihl + 7] == 0 else { return }
                var sum = transportChecksum(base: base, ihl: ihl, proto: proto, payloadLen: payloadLen)
                if sum == 0 { sum = 0xffff }
                raw[ihl + 6] = UInt8(truncatingIfNeeded: sum >> 8)
                raw[ihl + 7] = UInt8(truncatingIfNeeded: sum)
            default:
                break
            }
        }
    }

    private static func transportChecksum(
        base: UnsafeMutableRawPointer,
        ihl: Int,
        proto: UInt8,
        payloadLen: Int
    ) -> UInt16 {
        var sum: UInt32 = 0
        let srcDst = UnsafeRawBufferPointer(start: base + 12, count: 8)
        var offset = 0
        while offset < 8 {
            sum += UInt32(srcDst[offset]) << 8 | UInt32(srcDst[offset + 1])
            offset += 2
        }
        sum += UInt32(proto)
        sum += UInt32(payloadLen)
        let payload = UnsafeRawBufferPointer(start: base + ihl, count: payloadLen)
        var index = 0
        while index + 1 < payload.count {
            sum += UInt32(payload[index]) << 8 | UInt32(payload[index + 1])
            index += 2
        }
        if index < payload.count {
            sum += UInt32(payload[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { read32($0, offset) }
    }

    static func read32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        guard bytes.count >= offset + 4 else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

enum Ethernet {
    static let headerLength = 14
    static let typeARP: UInt16 = 0x0806
    static let typeIPv4: UInt16 = 0x0800
    static let protoICMP: UInt8 = 1
    static let protoTCP: UInt8 = 6
    static let protoUDP: UInt8 = 17

    static func frame(dst: MACAddress, src: MACAddress, type: UInt16, payload: Data) -> Data {
        var out = Data(capacity: headerLength + payload.count)
        out.append(contentsOf: dst.bytes)
        out.append(contentsOf: src.bytes)
        out.append(UInt8(type >> 8))
        out.append(UInt8(type & 0xff))
        out.append(payload)
        return out
    }

    static func parse(_ frame: Data) -> (dst: MACAddress, src: MACAddress, type: UInt16, payload: Data)? {
        frame.withUnsafeBytes { bytes -> (MACAddress, MACAddress, UInt16, Data)? in
            guard bytes.count >= headerLength else { return nil }
            guard let dst = try? MACAddress(Array(bytes[0..<6])),
                let src = try? MACAddress(Array(bytes[6..<12]))
            else { return nil }
            let type = UInt16(bytes[12]) << 8 | UInt16(bytes[13])
            return (dst, src, type, frame.subdata(in: headerLength..<frame.count))
        }
    }

    static func checksum(_ data: Data) -> UInt16 {
        data.withUnsafeBytes { checksum($0) }
    }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }
}

enum ARP {
    static func parseRequest(_ payload: Data) -> (senderIP: IPv4Address, targetIP: IPv4Address)? {
        payload.withUnsafeBytes { parseRequest($0) }
    }

    static func parseRequest(_ payload: UnsafeRawBufferPointer) -> (senderIP: IPv4Address, targetIP: IPv4Address)? {
        guard payload.count >= 28 else { return nil }
        let oper = UInt16(payload[6]) << 8 | UInt16(payload[7])
        guard oper == 1 else { return nil }
        return (IPv4Address(IPv4Peek.read32(payload, 14)), IPv4Address(IPv4Peek.read32(payload, 24)))
    }

    /// Ethernet frame: src MAC + ARP who-has.
    static func parseEthernetRequest(
        _ frame: UnsafeRawBufferPointer
    ) -> (srcMAC: MACAddress, senderIP: IPv4Address, targetIP: IPv4Address)? {
        guard frame.count >= Ethernet.headerLength + 28 else { return nil }
        let payload = UnsafeRawBufferPointer(rebasing: frame[Ethernet.headerLength...])
        guard let request = parseRequest(payload) else { return nil }
        guard let srcMAC = try? MACAddress(Array(frame[6..<12])) else { return nil }
        return (srcMAC, request.senderIP, request.targetIP)
    }

    static func reply(senderMAC: MACAddress, senderIP: IPv4Address, targetMAC: MACAddress, targetIP: IPv4Address) -> Data {
        var out = Data(count: 28)
        out[0] = 0
        out[1] = 1
        out[2] = 0x08
        out[3] = 0x00
        out[4] = 6
        out[5] = 4
        out[6] = 0
        out[7] = 2
        let sm = senderMAC.bytes
        let sip = senderIP.bytes
        let tm = targetMAC.bytes
        let tip = targetIP.bytes
        for i in 0..<6 { out[8 + i] = sm[i] }
        for i in 0..<4 { out[14 + i] = sip[i] }
        for i in 0..<6 { out[18 + i] = tm[i] }
        for i in 0..<4 { out[24 + i] = tip[i] }
        return out
    }
}

struct IPv4Packet {
    /// The gateway only ever writes option-free headers.
    static let headerLength = 20

    var tos: UInt8
    var id: UInt16
    var ttl: UInt8
    var proto: UInt8
    var src: IPv4Address
    var dst: IPv4Address
    var payload: Data

    static func parse(_ data: Data) -> IPv4Packet? {
        data.withUnsafeBytes { bytes -> IPv4Packet? in
            guard bytes.count >= headerLength else { return nil }
            let ihl = Int(bytes[0] & 0x0f) * 4
            guard bytes[0] >> 4 == 4, ihl >= headerLength, bytes.count >= ihl else { return nil }
            let total = Int(bytes[2]) << 8 | Int(bytes[3])
            guard total >= ihl, bytes.count >= total else { return nil }
            return IPv4Packet(
                tos: bytes[1],
                id: UInt16(bytes[4]) << 8 | UInt16(bytes[5]),
                ttl: bytes[8],
                proto: bytes[9],
                src: IPv4Address(IPv4Peek.read32(bytes, 12)),
                dst: IPv4Address(IPv4Peek.read32(bytes, 16)),
                payload: data.subdata(in: ihl..<total)
            )
        }
    }

    func encode() -> Data {
        var header = Data(count: Self.headerLength)
        header[0] = 0x45 // IPv4, 5-word header
        header[1] = tos
        let total = Self.headerLength + payload.count
        header[2] = UInt8(truncatingIfNeeded: total >> 8)
        header[3] = UInt8(truncatingIfNeeded: total)
        header[4] = UInt8(truncatingIfNeeded: id >> 8)
        header[5] = UInt8(truncatingIfNeeded: id)
        header[8] = ttl == 0 ? 64 : ttl
        header[9] = proto
        let srcb = src.bytes
        let dstb = dst.bytes
        for i in 0..<4 { header[12 + i] = srcb[i] }
        for i in 0..<4 { header[16 + i] = dstb[i] }
        let sum = Ethernet.checksum(header)
        header[10] = UInt8(truncatingIfNeeded: sum >> 8)
        header[11] = UInt8(truncatingIfNeeded: sum)
        return header + payload
    }
}

/// Parsed TCP header plus payload. Only the fields the gateway acts on.
struct TCPSegment {
    struct Flags: OptionSet {
        let rawValue: UInt8

        static let fin = Flags(rawValue: 0x01)
        static let syn = Flags(rawValue: 0x02)
        static let rst = Flags(rawValue: 0x04)
        static let push = Flags(rawValue: 0x08)
        static let ack = Flags(rawValue: 0x10)

        static let synAck: Flags = [.syn, .ack]
        static let finAck: Flags = [.fin, .ack]
        static let pushAck: Flags = [.push, .ack]
    }

    static let headerLength = 20

    var srcPort: UInt16
    var dstPort: UInt16
    var seq: UInt32
    var ack: UInt32
    var window: UInt16
    var flags: Flags
    var payload: Data

    static func parse(_ data: Data) -> TCPSegment? {
        data.withUnsafeBytes { bytes -> TCPSegment? in
            guard bytes.count >= headerLength else { return nil }
            let dataOffset = Int(bytes[12] >> 4) * 4
            let payload = dataOffset < bytes.count && dataOffset >= headerLength
                ? data.subdata(in: dataOffset..<data.count)
                : Data()
            return TCPSegment(
                srcPort: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
                dstPort: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                seq: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]),
                ack: UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]),
                window: UInt16(bytes[14]) << 8 | UInt16(bytes[15]),
                flags: Flags(rawValue: bytes[13]),
                payload: payload
            )
        }
    }
}

struct UDPDatagram {
    var srcPort: UInt16
    var dstPort: UInt16
    var payload: Data

    static func parse(_ data: Data) -> UDPDatagram? {
        data.withUnsafeBytes { bytes -> UDPDatagram? in
            guard bytes.count >= 8 else { return nil }
            let src = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let dst = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            let length = Int(bytes[4]) << 8 | Int(bytes[5])
            guard length >= 8, bytes.count >= length else { return nil }
            return UDPDatagram(srcPort: src, dstPort: dst, payload: data.subdata(in: 8..<length))
        }
    }

    func encode(src: IPv4Address, dst: IPv4Address) -> Data {
        var header = Data(count: 8)
        header[0] = UInt8(truncatingIfNeeded: srcPort >> 8)
        header[1] = UInt8(truncatingIfNeeded: srcPort)
        header[2] = UInt8(truncatingIfNeeded: dstPort >> 8)
        header[3] = UInt8(truncatingIfNeeded: dstPort)
        let length = 8 + payload.count
        header[4] = UInt8(truncatingIfNeeded: length >> 8)
        header[5] = UInt8(truncatingIfNeeded: length)
        var pseudo = Data()
        pseudo.append(contentsOf: src.bytes)
        pseudo.append(contentsOf: dst.bytes)
        pseudo.append(0)
        pseudo.append(Ethernet.protoUDP)
        pseudo.append(UInt8(truncatingIfNeeded: length >> 8))
        pseudo.append(UInt8(truncatingIfNeeded: length))
        let sum = Ethernet.checksum(pseudo + header + payload)
        let encoded = sum == 0 ? 0xffff : sum
        header[6] = UInt8(truncatingIfNeeded: encoded >> 8)
        header[7] = UInt8(truncatingIfNeeded: encoded)
        return header + payload
    }
}
