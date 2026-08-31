import ContainerizationExtras
import Foundation
import SystemConfiguration
import os

/// Minimal DNS A-record codec for the embedded gateway resolver.
enum GatewayDNS {
    static let typeA: UInt16 = 1
    static let typeAAAA: UInt16 = 28
    /// Last-resort resolvers when the Mac has none. Prefer ``systemServers``.
    static let fallback: [String] = ["1.1.1.1", "8.8.8.8"]
    /// Resolvers for names the gateway does not own. Follows macOS / Clash DNS when possible.
    static var upstream: [String] {
        let servers = systemServers()
        return servers.isEmpty ? fallback : servers
    }
    static var primaryUpstream: String { upstream[0] }

    /// Empty / invalid `--dns` falls back to ``upstream``.
    static func upstreams(for nameservers: [String]) -> [String] {
        let trimmed = nameservers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? upstream : trimmed
    }

    /// IPv4 nameservers from `State:/Network/Global/DNS` (Clash/Surge TUN usually 127.0.0.1).
    static func systemServers() -> [String] {
        cache.withLock { state in
            let now = Date()
            if !state.servers.isEmpty, now.timeIntervalSince(state.at) < 5 {
                return state.servers
            }
            state.servers = readSystemServers()
            state.at = now
            return state.servers
        }
    }

    private struct Cache {
        var servers: [String] = []
        var at = Date.distantPast
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    private static func readSystemServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "io.macker.dns" as CFString, nil, nil),
            let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
            let addresses = value["ServerAddresses"] as? [String]
        else { return [] }
        return addresses.filter { address in
            address.contains(".") && !address.contains(":")
        }
    }
    struct Question: Equatable {
        var name: String
        var type: UInt16
        var dnsClass: UInt16
        var id: UInt16
    }

    static func parseQuery(_ packet: Data) -> Question? {
        packet.withUnsafeBytes { bytes -> Question? in
            guard bytes.count >= 12 else { return nil }
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
    }

    static func lookup(
        name: String,
        records: [NetworkGateway.Record],
        visibleNetworks: Set<String>
    ) -> IPv4Address? {
        let needle = name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !needle.isEmpty else { return nil }
        return match(needle, in: records.filter { visibleNetworks.contains($0.networkID) })
    }

    static func match(_ needle: String, in records: [NetworkGateway.Record]) -> IPv4Address? {
        for record in records {
            let names = [record.containerName, record.hostname, String(record.containerID.prefix(12))]
                + record.aliases
            for raw in names {
                let candidate = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                if candidate == needle || "\(candidate).\(record.networkName)" == needle {
                    return record.ip
                }
            }
            if needle.count >= 12, record.containerID.lowercased().hasPrefix(needle) {
                return record.ip
            }
        }
        return nil
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

    private static func readName(_ bytes: UnsafeRawBufferPointer, offset: inout Int) -> String? {
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
            labels.append(String(decoding: bytes[cursor..<(cursor + len)], as: UTF8.self))
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
