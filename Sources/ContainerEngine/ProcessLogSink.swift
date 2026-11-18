import Containerization
import Foundation

/// Forwards guest stdout/stderr into the Docker log buffer and attach subscribers.
///
/// The SDK calls `write` synchronously; chunks are queued and handed to `handler` one at a
/// time, in order, by a single pump task. `drain()` lets the exit path wait until every
/// chunk the SDK wrote has been handled, so attach/log streams never close before their
/// last bytes (the SDK's `wait()` returns only after the guest closed stdout/stderr).
final class ProcessLogSink: Writer, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let pump: Task<Void, Never>

    init(hopping handler: @escaping @Sendable (Data) async -> Void) {
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        self.pump = Task {
            for await chunk in chunks {
                await handler(chunk)
            }
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        continuation.yield(data)
    }

    func close() throws {}

    /// Stops accepting output and waits until everything already written is handled.
    func drain() async {
        continuation.finish()
        await pump.value
    }

    deinit {
        continuation.finish()
    }
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
