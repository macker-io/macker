import Foundation
import Testing
@testable import ContainerEngine

struct DaemonInstanceLockTests {
    @Test func secondAcquireFailsUntilRelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try DaemonInstanceLock.acquire(storeDirectory: dir)
        #expect(throws: EngineError.self) {
            _ = try DaemonInstanceLock.acquire(storeDirectory: dir)
        }
        first.release()

        let second = try DaemonInstanceLock.acquire(storeDirectory: dir)
        second.release()
    }

    @Test func independentStoresDoNotContend() throws {
        let firstDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secondDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }

        let first = try DaemonInstanceLock.acquire(storeDirectory: firstDir)
        let second = try DaemonInstanceLock.acquire(storeDirectory: secondDir)
        first.release()
        second.release()
    }
}
