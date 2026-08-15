import Containerization
import Foundation

/// Forwards guest stdout/stderr into the Docker log buffer and attach subscribers.
final class ProcessLogSink: Writer, @unchecked Sendable {
    private let onChunk: @Sendable (String) -> Void

    init(onChunk: @escaping @Sendable (String) -> Void) {
        self.onChunk = onChunk
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        onChunk(String(decoding: data, as: UTF8.self))
    }

    func close() throws {}
}
