import ContainerizationExtras
import Darwin
import Foundation
import Network
import Testing
import os
@testable import ContainerEngine

private typealias IPv4Address = ContainerizationExtras.IPv4Address

/// Isolated-process CPU / memory numbers for the SwiftTCP gateway forwarder.
/// `swift test -c release --filter resourceBenchSwiftTCP`
@Suite(.serialized)
struct ForwarderResourceTests {
    private static let bytes = 64 * 1024 * 1024

    @Test func resourceBenchSwiftTCP() throws {
        try runResourceBench(name: "SwiftTCP", bytes: Self.bytes) { onGuest in
            GatewaySwiftTCP(onGuest: onGuest)
        }
    }
}

private func runResourceBench(
    name: String,
    bytes: Int,
    make: (@escaping @Sendable (IPv4Address, Data) -> Void) throws -> any GatewayForwarder
) throws {
    let beforeInit = resourceSnapshot()
    func attach(_ session: GuestTCPSession) throws -> any GatewayForwarder {
        let stack = try make { _, data in
            session.notePacket(data)
        }
        session.forwarder = stack
        return stack
    }

    let hostToGuest = try runOneDirection(bytes: bytes, hostSends: true, make: attach)
    let afterHost = resourceSnapshot()
    let guestToHost = try runOneDirection(bytes: bytes, hostSends: false, make: attach)
    let afterGuest = resourceSnapshot()

    print(resourceLine(
        name: name, direction: "host→guest", bytes: bytes,
        transfer: hostToGuest, before: beforeInit, after: afterHost
    ))
    print(resourceLine(
        name: name, direction: "guest→host", bytes: bytes,
        transfer: guestToHost, before: afterHost, after: afterGuest
    ))
    print(
        String(
            format: "RESOURCE %@ process: rss=%.1fMB footprint=%.1fMB (init rss=%.1fMB footprint=%.1fMB)",
            name,
            Double(afterGuest.rss) / 1_048_576.0,
            Double(afterGuest.footprint) / 1_048_576.0,
            Double(beforeInit.rss) / 1_048_576.0,
            Double(beforeInit.footprint) / 1_048_576.0
        )
    )
    #expect(hostToGuest.transferred == bytes)
    #expect(guestToHost.transferred == bytes)
}

private struct TransferStats {
    var transferred: Int
    var seconds: Double
    var mbps: Double
    var cpuUser: Double
    var cpuSys: Double
}

private struct ResourceSnap {
    var cpuUser: Double
    var cpuSys: Double
    var rss: UInt64
    var footprint: UInt64
}

private func resourceLine(
    name: String,
    direction: String,
    bytes: Int,
    transfer: TransferStats,
    before: ResourceSnap,
    after: ResourceSnap
) -> String {
    let cpu = transfer.cpuUser + transfer.cpuSys
    let cpuPercent = transfer.seconds > 0 ? cpu / transfer.seconds * 100 : 0
    let deltaRSS = Double(after.rss) - Double(before.rss)
    let deltaFoot = Double(after.footprint) - Double(before.footprint)
    return String(
        format: "RESOURCE %@ %@: %.1f Mbps  wall=%.3fs  cpu=%.3fs (user=%.3f sys=%.3f)  cpu%%=%.0f  Δrss=%+.1fMB Δfoot=%+.1fMB",
        name,
        direction,
        transfer.mbps,
        transfer.seconds,
        cpu,
        transfer.cpuUser,
        transfer.cpuSys,
        cpuPercent,
        deltaRSS / 1_048_576.0,
        deltaFoot / 1_048_576.0
    )
}

private func resourceSnapshot() -> ResourceSnap {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
    let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0

    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let status = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
        }
    }
    let rss = status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    let footprint = status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    return ResourceSnap(cpuUser: user, cpuSys: sys, rss: rss, footprint: footprint)
}

private func runOneDirection(
    bytes: Int,
    hostSends: Bool,
    make: (GuestTCPSession) throws -> any GatewayForwarder
) throws -> TransferStats {
    let listener = try NWListener(using: .tcp, on: .any)
    let listenerQueue = DispatchQueue(label: "test.forwarder.resource")
    let listenerReady = DispatchSemaphore(value: 0)
    let hostReceived = OSAllocatedUnfairLock<Int>(initialState: 0)
    let hostDone = DispatchSemaphore(value: 0)
    let guestReady = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
        if case .ready = state { listenerReady.signal() }
    }
    listener.newConnectionHandler = { connection in
        if hostSends {
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    listenerQueue.async {
                        _ = guestReady.wait(timeout: .now() + 5)
                        connection.send(content: Data(count: bytes), completion: .contentProcessed { _ in
                            connection.send(content: nil, isComplete: true, completion: .idempotent)
                        })
                    }
                }
            }
        } else {
            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, _ in
                    if let data {
                        hostReceived.withLock { $0 += data.count }
                    }
                    if hostReceived.withLock({ $0 }) >= bytes || complete {
                        hostDone.signal()
                        return
                    }
                    receive()
                }
            }
            receive()
        }
        connection.start(queue: listenerQueue)
    }
    listener.start(queue: listenerQueue)
    defer { listener.cancel() }
    #expect(listenerReady.wait(timeout: .now() + 2) == .success)
    let hostPort = try #require(listener.port?.rawValue)

    let session = GuestTCPSession(
        guest: IPv4Address(0xAC11_0002),
        remote: IPv4Address(0x7F00_0001),
        hostPort: hostPort
    )
    let stack = try make(session)
    defer { stack.closeAll() }
    try session.handshake()
    guestReady.signal()

    let before = resourceSnapshot()
    let started = Date()
    let transferred = session.transfer(
        bytes: bytes, hostSends: hostSends, hostReceived: hostReceived, hostDone: hostDone,
        deadlineSeconds: 30
    )
    let elapsed = max(Date().timeIntervalSince(started), 0.000_001)
    let after = resourceSnapshot()
    return TransferStats(
        transferred: transferred,
        seconds: elapsed,
        mbps: Double(transferred) * 8.0 / elapsed / 1_000_000.0,
        cpuUser: max(0, after.cpuUser - before.cpuUser),
        cpuSys: max(0, after.cpuSys - before.cpuSys)
    )
}

