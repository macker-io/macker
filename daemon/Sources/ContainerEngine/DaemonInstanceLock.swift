import Darwin
import Foundation
import os

/// Exclusive owner of a daemon store directory.
///
/// Two processes must not share image/container/volume state. The lock lives next to that
/// state, not next to the API socket, so a second `--socket` cannot open a second engine
/// against the same store. `flock` is released if the process exits or crashes; `O_CLOEXEC`
/// keeps MicroVM helper forks from inheriting it.
public final class DaemonInstanceLock: @unchecked Sendable {
    public let path: String
    private let descriptor = OSAllocatedUnfairLock<Int32>(uncheckedState: -1)

    public static func lockPath(in storeDirectory: URL) -> String {
        storeDirectory.appendingPathComponent("daemon.lock").path
    }

    public static func acquire(storeDirectory: URL = DaemonPaths.storeDirectory) throws -> DaemonInstanceLock {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let lock = DaemonInstanceLock(path: lockPath(in: storeDirectory))
        try lock.acquire()
        return lock
    }

    private init(path: String) {
        self.path = path
    }

    deinit {
        release()
    }

    public func release() {
        let fd = descriptor.withLock { current -> Int32 in
            let value = current
            current = -1
            return value
        }
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    private func acquire() throws {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
        guard fd >= 0 else {
            let code = errno
            throw EngineError.runtimeUnavailable("failed to lock \(path) (errno \(code))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw EngineError.conflict("another daemon is already running for \(path)")
            }
            throw EngineError.runtimeUnavailable("failed to lock \(path) (errno \(code))")
        }
        descriptor.withLock { $0 = fd }
    }
}
