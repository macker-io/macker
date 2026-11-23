import Darwin
import Foundation
import Testing
@testable import HelperSupport

struct HelperRequestDefenseTests {
    @Test func admissionRejectsBeyondLimitThenRecovers() {
        let gate = HelperConnectionAdmission(limit: 2)
        #expect(gate.tryAcquire())
        #expect(gate.tryAcquire())
        #expect(!gate.tryAcquire())
        #expect(gate.activeCount == 2)
        gate.release()
        #expect(gate.activeCount == 1)
        #expect(gate.tryAcquire())
        gate.release()
        gate.release()
        #expect(gate.activeCount == 0)
    }

    @Test func readLineTimesOutOnIncompleteRequest() throws {
        let pair = try SocketPair.make()
        defer { pair.close() }
        let started = DispatchTime.now()
        let error = #expect(throws: HelperError.self) {
            _ = try HelperChannel.readLine(pair.reader, deadline: .after(0.15))
        }
        #expect(error == .unavailable("helper request read timed out"))
        let elapsedMs =
            Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000
        #expect(elapsedMs >= 120)
        #expect(elapsedMs < 1_500)
    }

    @Test func readLineAbsoluteDeadlineNotExtendedByTrickle() throws {
        let pair = try SocketPair.make()
        defer { pair.close() }

        let trickle = DispatchQueue(label: "helper.defense.trickle")
        let stop = crossThreadFlag()
        let writerDone = DispatchGroup()
        writerDone.enter()
        trickle.async {
            defer { writerDone.leave() }
            // Bytes arrive often enough that an inactivity/idle timer would keep resetting,
            // but the absolute deadline must still fire.
            while !stop.isSet {
                _ = Darwin.write(pair.writer, "x", 1)
                usleep(40_000)
            }
        }
        defer {
            stop.set()
            // Join the writer before socket teardown so close cannot race a live write.
            #expect(writerDone.wait(timeout: .now() + 1) == .success)
        }

        let started = DispatchTime.now()
        let error = #expect(throws: HelperError.self) {
            _ = try HelperChannel.readLine(pair.reader, deadline: .after(0.2))
        }
        #expect(error == .unavailable("helper request read timed out"))
        let elapsedMs =
            Double(DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000
        #expect(elapsedMs >= 150)
        #expect(elapsedMs < 1_500)
    }

    @Test func readLineAcceptsNormalRequestBeforeDeadline() throws {
        let pair = try SocketPair.make()
        defer { pair.close() }
        let body = try JSONEncoder().encode(HelperRequest.ping)
        try HelperChannel.writeLine(pair.writer, body)
        let data = try HelperChannel.readLine(pair.reader, deadline: .after(1))
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
        #expect(decoded == .ping)
    }

    @Test func incompleteClientDoesNotBlockAdmittedPeer() throws {
        let pairA = try SocketPair.make()
        let pairB = try SocketPair.make()
        defer {
            pairA.close()
            pairB.close()
        }

        let admission = HelperConnectionAdmission(limit: 2)
        #expect(admission.tryAcquire())
        #expect(admission.tryAcquire())
        // Deterministic: both slots held before any worker can release.
        #expect(!admission.tryAcquire())

        let queue = DispatchQueue(label: "helper.defense.peers", attributes: .concurrent)
        let group = DispatchGroup()

        group.enter()
        queue.async {
            defer {
                admission.release()
                group.leave()
            }
            // Stall: never send a newline.
            _ = try? HelperChannel.readLine(pairA.reader, deadline: .after(0.4))
        }

        let pingBody = try JSONEncoder().encode(HelperRequest.ping)
        try HelperChannel.writeLine(pairB.writer, pingBody)

        group.enter()
        let peerResult = LockedBox<Result<HelperRequest, Error>?>(nil)
        queue.async {
            defer {
                admission.release()
                group.leave()
            }
            do {
                let data = try HelperChannel.readLine(pairB.reader, deadline: .after(0.4))
                let req = try JSONDecoder().decode(HelperRequest.self, from: data)
                peerResult.value = .success(req)
            } catch {
                peerResult.value = .failure(error)
            }
        }

        let finished = group.wait(timeout: .now() + 2)
        #expect(finished == .success)
        #expect(try peerResult.value?.get() == .ping)
        #expect(admission.activeCount == 0)
    }

    @Test func oversizedRequestStillRejected() throws {
        let pair = try SocketPair.make()
        defer { pair.close() }

        // Bound the producer so a full socket buffer cannot hang the test forever.
        try HelperChannel.setSendTimeout(pair.writer, seconds: 1)

        let writerDone = DispatchGroup()
        writerDone.enter()
        DispatchQueue(label: "helper.defense.oversize").async {
            defer { writerDone.leave() }
            let huge = Data(repeating: UInt8(ascii: "a"), count: 65_536)
            _ = try? HelperChannel.writeLine(pair.writer, huge)
        }
        defer {
            #expect(writerDone.wait(timeout: .now() + 2) == .success)
        }

        let error = #expect(throws: HelperError.self) {
            _ = try HelperChannel.readLine(pair.reader, deadline: .after(1))
        }
        #expect(error == .invalidRequest("helper request too large"))
    }
}

// MARK: - Test helpers

private struct SocketPair {
    let reader: Int32
    let writer: Int32

    static func make() throws -> SocketPair {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard rc == 0 else {
            throw HelperError.unavailable("socketpair failed")
        }
        return SocketPair(reader: fds[0], writer: fds[1])
    }

    func close() {
        Darwin.close(reader)
        Darwin.close(writer)
    }
}

private final class CrossThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

private func crossThreadFlag() -> CrossThreadFlag { CrossThreadFlag() }

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
