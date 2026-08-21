import Foundation
import os

enum RunSync {
    static func call<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let lock = OSAllocatedUnfairLock<Result<T, Error>?>(uncheckedState: nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let result: Result<T, Error>
            do {
                result = .success(try await body())
            } catch {
                result = .failure(error)
            }
            lock.withLock { $0 = result }
            semaphore.signal()
        }
        semaphore.wait()
        return try lock.withLock { $0 }.unsafelyUnwrapped.get()
    }
}
