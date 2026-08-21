import Foundation
import NIOCore

enum JSONBody {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func encodeData(_ value: some Encodable) -> Data {
        (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func encode(_ value: some Encodable) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeBytes(encodeData(value))
        return buffer
    }

    static func encodeLine(_ value: some Encodable) -> ByteBuffer {
        var buffer = encode(value)
        buffer.writeString("\n")
        return buffer
    }
}
