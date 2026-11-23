import Foundation

/// Caps how many helper client connections may be in flight at once.
/// Rejects surplus accepts immediately so one stall cannot exhaust the process.
public final class HelperConnectionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var inFlight = 0

    public init(limit: Int) {
        precondition(limit > 0, "admission limit must be positive")
        self.limit = limit
    }

    public var limitValue: Int { limit }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    /// Returns `true` when this connection may proceed; caller must `release()` exactly once.
    public func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        precondition(inFlight > 0, "release without matching acquire")
        inFlight -= 1
    }
}
