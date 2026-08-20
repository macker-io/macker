import ContainerizationExtras
import Foundation

/// Minimal DNS A-record codec for the embedded gateway resolver.
enum GatewayDNS {
    static let typeA: UInt16 = 1
    static let typeAAAA: UInt16 = 28
    /// Resolvers for names the gateway does not own. The guest's `resolv.conf` still points at
    /// the gateway; these are used only when recursing. `--dns` replaces this list.
    static let upstream: [String] = ["1.1.1.1", "8.8.8.8"]
    static var primaryUpstream: String { upstream[0] }

    /// Empty / invalid `--dns` falls back to ``upstream``.
    static func upstreams(for nameservers: [String]) -> [String] {
        let trimmed = nameservers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? upstream : trimmed
    }
    struct Question: Equatable {
        var name: String
        var type: UInt16
        var dnsClass: UInt16
        var id: UInt16
    }

    static func parseQuery(_ packet: Data) -> Question? {
        guard packet.count >= 12 else { return nil }
        let bytes = [UInt8](packet)
        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let flags = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let qdcount = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard flags & 0x8000 == 0, qdcount >= 1 else { return nil }
        var offset = 12
        guard let name = readName(bytes, offset: &offset) else { return nil }
        guard offset + 4 <= bytes.count else { return nil }
        let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        let cls = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
        return Question(name: name, type: type, dnsClass: cls, id: id)
    }

    static func answer(
        id: UInt16,
        name: String,
        address: IPv4Address?,
        nxdomain: Bool = false,
        type: UInt16 = typeA
    ) -> Data {
        var out = Data()
        func append16(_ value: UInt16) {
            out.append(UInt8(value >> 8))
            out.append(UInt8(value & 0xff))
        }
        append16(id)
        if let address {
            append16(0x8400)
            append16(1)
            append16(1)
            append16(0)
            append16(0)
            appendName(name, to: &out)
            append16(type)
            append16(1)
            out.append(0xc0)
            out.append(0x0c)
            append16(typeA)
            append16(1)
            out.append(contentsOf: [0, 0, 0, 30])
            append16(4)
            out.append(contentsOf: address.bytes)
        } else {
            append16(nxdomain ? 0x8403 : 0x8400)
            append16(1)
            append16(0)
            append16(0)
            append16(0)
            appendName(name, to: &out)
            append16(type)
            append16(1)
        }
        return out
    }

    private static func readName(_ bytes: [UInt8], offset: inout Int) -> String? {
        var labels: [String] = []
        var jumped = false
        var cursor = offset
        var hops = 0
        while cursor < bytes.count, hops < 16 {
            hops += 1
            let len = Int(bytes[cursor])
            if len == 0 {
                cursor += 1
                if !jumped { offset = cursor }
                return labels.joined(separator: ".")
            }
            if len & 0xc0 == 0xc0 {
                guard cursor + 1 < bytes.count else { return nil }
                let pointer = Int(len & 0x3f) << 8 | Int(bytes[cursor + 1])
                if !jumped {
                    offset = cursor + 2
                    jumped = true
                }
                cursor = pointer
                continue
            }
            cursor += 1
            guard cursor + len <= bytes.count else { return nil }
            labels.append(String(bytes: bytes[cursor..<(cursor + len)], encoding: .ascii) ?? "")
            cursor += len
        }
        return nil
    }

    private static func appendName(_ name: String, to data: inout Data) {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !trimmed.isEmpty {
            for label in trimmed.split(separator: ".") {
                let bytes = Array(label.utf8)
                data.append(UInt8(bytes.count))
                data.append(contentsOf: bytes)
            }
        }
        data.append(0)
    }
}
