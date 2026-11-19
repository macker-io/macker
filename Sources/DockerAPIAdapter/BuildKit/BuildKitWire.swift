import ContainerizationOCI
import Foundation

/// Just enough protobuf and gRPC framing to edit the BuildKit `Control` messages that Docker's
/// built-in BuildKit treats specially. Unknown fields are carried through byte-for-byte.
enum ProtoWire {
    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(Data)
        case bytes(Data)
        case fixed32(Data)
    }

    struct Field: Equatable {
        var number: Int
        var value: Value
    }

    struct DecodeError: Error {}

    static func decode(_ data: Data) throws -> [Field] {
        var fields: [Field] = []
        var index = data.startIndex
        while index < data.endIndex {
            let key = try readVarint(data, &index)
            let number = Int(key >> 3)
            guard number > 0 else { throw DecodeError() }
            switch key & 7 {
            case 0:
                fields.append(Field(number: number, value: .varint(try readVarint(data, &index))))
            case 1:
                guard data.endIndex - index >= 8 else { throw DecodeError() }
                fields.append(Field(number: number, value: .fixed64(data[index..<index + 8])))
                index += 8
            case 2:
                let length = Int(try readVarint(data, &index))
                guard length >= 0, data.endIndex - index >= length else { throw DecodeError() }
                fields.append(Field(number: number, value: .bytes(Data(data[index..<index + length]))))
                index += length
            case 5:
                guard data.endIndex - index >= 4 else { throw DecodeError() }
                fields.append(Field(number: number, value: .fixed32(data[index..<index + 4])))
                index += 4
            default:
                throw DecodeError()
            }
        }
        return fields
    }

    static func encode(_ fields: [Field]) -> Data {
        var out = Data()
        for field in fields {
            switch field.value {
            case .varint(let value):
                writeVarint(UInt64(field.number << 3), into: &out)
                writeVarint(value, into: &out)
            case .fixed64(let raw):
                writeVarint(UInt64(field.number << 3 | 1), into: &out)
                out.append(raw)
            case .bytes(let raw):
                writeVarint(UInt64(field.number << 3 | 2), into: &out)
                writeVarint(UInt64(raw.count), into: &out)
                out.append(raw)
            case .fixed32(let raw):
                writeVarint(UInt64(field.number << 3 | 5), into: &out)
                out.append(raw)
            }
        }
        return out
    }

    static func string(_ value: String, field: Int) -> Field {
        Field(number: field, value: .bytes(Data(value.utf8)))
    }

    /// `map<string,string>` entry.
    static func mapEntry(_ key: String, _ value: String, field: Int) -> Field {
        Field(number: field, value: .bytes(encode([string(key, field: 1), string(value, field: 2)])))
    }

    static func decodeMapEntry(_ data: Data) throws -> (String, String) {
        var key = ""
        var value = ""
        for field in try decode(data) {
            guard case .bytes(let raw) = field.value else { continue }
            if field.number == 1 { key = String(decoding: raw, as: UTF8.self) }
            if field.number == 2 { value = String(decoding: raw, as: UTF8.self) }
        }
        return (key, value)
    }

    private static func readVarint(_ data: Data, _ index: inout Data.Index) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw DecodeError() }
        }
        throw DecodeError()
    }

    static func writeVarint(_ value: UInt64, into out: inout Data) {
        var value = value
        while value >= 0x80 {
            out.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
    }
}

/// gRPC length-prefixed messages (`[flag:1][length:4 BE][payload]`).
enum GRPCFraming {
    static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(0)
        let length = UInt32(payload.count)
        out.append(UInt8(length >> 24))
        out.append(UInt8(length >> 16 & 0xff))
        out.append(UInt8(length >> 8 & 0xff))
        out.append(UInt8(length & 0xff))
        out.append(payload)
        return out
    }

    /// Removes complete messages from the front of `buffer`. `compressed` messages are
    /// returned as `nil` payloads (the caller passes them through untouched).
    static func takeMessages(_ buffer: inout Data) -> [(compressed: Bool, payload: Data)] {
        var messages: [(Bool, Data)] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let length = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16
                | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            guard buffer.count >= 5 + length else { break }
            let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
            messages.append((buffer[start] != 0, payload))
            buffer = Data(buffer[(start + 5 + length)...])
        }
        return messages
    }
}

/// The two BuildKit `Control` messages the proxy edits.
///
/// Docker's daemon embeds BuildKit with a private `moby` exporter that writes into its image
/// store. A standalone `buildkitd` has no such exporter, so `moby` becomes the standard `image`
/// exporter (which stores into BuildKit's content store) and the daemon imports the result.
enum BuildKitControl {
    static let solvePath = "/moby.buildkit.v1.Control/Solve"
    static let sessionPath = "/moby.buildkit.v1.Control/Session"

    struct MobyExport: Equatable {
        /// Image names from the exporter's `name` attribute (comma-separated in BuildKit).
        var names: [String]
    }

    /// Rewrites `SolveRequest` exporters of type `moby` to `image`. Returns `nil` exports when
    /// nothing was rewritten.
    static func rewriteSolveRequest(_ payload: Data) throws -> (payload: Data, export: MobyExport?) {
        var fields = try ProtoWire.decode(payload)
        var export: MobyExport?
        for index in fields.indices {
            switch fields[index].number {
            case 13:  // repeated Exporter Exporters
                guard case .bytes(let raw) = fields[index].value else { continue }
                var exporter = try ProtoWire.decode(raw)
                guard exporterType(exporter) == "moby" else { continue }
                var names: [String] = []
                for i in exporter.indices {
                    if exporter[i].number == 1 {
                        exporter[i] = ProtoWire.string("image", field: 1)
                    } else if exporter[i].number == 2, case .bytes(let entry) = exporter[i].value {
                        let (key, value) = try ProtoWire.decodeMapEntry(entry)
                        if key == "name" { names += splitNames(value) }
                    }
                }
                fields[index].value = .bytes(ProtoWire.encode(exporter))
                export = MobyExport(names: (export?.names ?? []) + names)
            case 3:  // string ExporterDeprecated
                guard case .bytes(let raw) = fields[index].value, String(decoding: raw, as: UTF8.self) == "moby" else { continue }
                fields[index] = ProtoWire.string("image", field: 3)
                var names: [String] = []
                for field in fields where field.number == 4 {
                    if case .bytes(let entry) = field.value {
                        let (key, value) = try ProtoWire.decodeMapEntry(entry)
                        if key == "name" { names += splitNames(value) }
                    }
                }
                export = MobyExport(names: (export?.names ?? []) + names)
            default:
                continue
            }
        }
        guard let export else { return (payload, nil) }
        return (ProtoWire.encode(fields), export)
    }

    /// `SolveResponse.ExporterResponse` (`map<string,string>` field 1).
    static func exporterResponse(_ payload: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        for field in try ProtoWire.decode(payload) where field.number == 1 {
            if case .bytes(let entry) = field.value {
                let (key, value) = try ProtoWire.decodeMapEntry(entry)
                result[key] = value
            }
        }
        return result
    }

    /// The exporter reports a base64-encoded OCI descriptor alongside the image digest.
    static func localizeExporterResponse(_ payload: Data, upstreamDigest: String, local: Descriptor) throws -> Data {
        guard local.digest != upstreamDigest else { return payload }
        return try rewriteExporterResponse(payload, set: [
            "containerimage.digest": local.digest,
            "containerimage.descriptor": JSONEncoder().encode(local).base64EncodedString(),
        ])
    }

    /// Replaces map entries in a `SolveResponse`, keeping every other field.
    static func rewriteExporterResponse(_ payload: Data, set updates: [String: String]) throws -> Data {
        var fields: [ProtoWire.Field] = []
        var pending = updates
        for field in try ProtoWire.decode(payload) {
            if field.number == 1, case .bytes(let entry) = field.value {
                let (key, _) = try ProtoWire.decodeMapEntry(entry)
                if let value = pending.removeValue(forKey: key) {
                    fields.append(ProtoWire.mapEntry(key, value, field: 1))
                    continue
                }
            }
            fields.append(field)
        }
        for (key, value) in pending.sorted(by: { $0.key < $1.key }) {
            fields.append(ProtoWire.mapEntry(key, value, field: 1))
        }
        return ProtoWire.encode(fields)
    }

    /// `BytesMessage { bytes data = 1; }` used by the `Session` stream.
    static func bytesMessage(_ data: Data) -> Data {
        ProtoWire.encode([ProtoWire.Field(number: 1, value: .bytes(data))])
    }

    static func bytesMessageData(_ payload: Data) throws -> Data {
        var out = Data()
        for field in try ProtoWire.decode(payload) where field.number == 1 {
            if case .bytes(let raw) = field.value { out.append(raw) }
        }
        return out
    }

    private static func exporterType(_ fields: [ProtoWire.Field]) -> String? {
        for field in fields where field.number == 1 {
            if case .bytes(let raw) = field.value { return String(decoding: raw, as: UTF8.self) }
        }
        return nil
    }

    private static func splitNames(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
