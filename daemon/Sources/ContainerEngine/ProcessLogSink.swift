import Containerization
import Foundation

/// Forwards guest stdout/stderr into the Docker log buffer and attach subscribers.
final class ProcessLogSink: Writer, @unchecked Sendable {
    private let onChunk: @Sendable (Data) -> Void

    init(onChunk: @escaping @Sendable (Data) -> Void) {
        self.onChunk = onChunk
    }

    /// Hop onto an async target from the SDK's synchronous `Writer.write`.
    init(hopping handler: @escaping @Sendable (Data) async -> Void) {
        self.onChunk = { data in
            Task { await handler(data) }
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        onChunk(data)
    }

    func close() throws {}
}

/// Host-side stdin pipe for a guest process (`ReaderStream` for the SDK).
final class ProcessStdin: ReaderStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let bytes: AsyncStream<Data>

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        self.bytes = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func stream() -> AsyncStream<Data> {
        bytes
    }

    func yield(_ data: Data) {
        guard !data.isEmpty else { return }
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }

    deinit {
        continuation.finish()
    }
}
