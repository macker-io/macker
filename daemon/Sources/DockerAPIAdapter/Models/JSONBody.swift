import Foundation
import NIOCore

enum JSONBody {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func encode(_ value: some Encodable) -> ByteBuffer {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        return buffer
    }

    static func encodeLine(_ value: some Encodable) -> ByteBuffer {
        var buffer = encode(value)
        buffer.writeString("\n")
        return buffer
    }
}
