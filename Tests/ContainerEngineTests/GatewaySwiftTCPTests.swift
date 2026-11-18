import ContainerizationExtras
import Foundation
import Network
import Testing
import os
@testable import ContainerEngine

private typealias IPv4Address = ContainerizationExtras.IPv4Address

@Suite(.serialized)
struct GatewaySwiftTCPTests {
    @Test func bridgesTCPPayloadThroughAMacSocket() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let listenerQueue = DispatchQueue(label: "test.swifttcp.listener")
        let listenerReady = OSAllocatedUnfairLock(initialState: false)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.withLock { $0 = true } }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: Data("hello-from-host".utf8), completion: .idempotent)
                }
            }
            connection.start(queue: listenerQueue)
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }
        let ready = try await waitUntil(timeout: .seconds(1)) { listenerReady.withLock { $0 } }
        try #require(ready, "TCP listener did not become ready")
        let hostPort = try #require(listener.port?.rawValue)

        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x7F00_0001)
        let outputs = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let stack = GatewaySwiftTCP { _, data in
            outputs.withLock { $0.append(data) }
        }
        defer { stack.closeAll() }

        let syn = makeTCPPacket(
            src: guest, dst: remote, srcPort: 40_000, dstPort: hostPort,
            seq: 7, flags: TCPSegment.Flags.syn.rawValue
        )
        let synPacket = IPv4Packet(
            tos: 0, id: 1, ttl: 64, proto: Ethernet.protoTCP,
            src: guest, dst: remote, payload: syn
        )
        stack.handleTCP(packet: synPacket, segment: try #require(TCPSegment.parse(syn)))
        let replied = try await waitUntil(timeout: .seconds(2)) { outputs.withLock { !$0.isEmpty } }
        try #require(replied, "Gateway did not reply to SYN")
        let synAckData = try #require(outputs.withLock { $0.first })
        let synAckPacket = try #require(IPv4Packet.parse(synAckData))
        let synAckSegment = try #require(TCPSegment.parse(synAckPacket.payload))
        try #require(synAckSegment.flags.contains(.synAck))
        let ack = makeTCPPacket(
            src: guest, dst: remote, srcPort: 40_000, dstPort: hostPort,
            seq: 8, ack: synAckSegment.seq &+ 1, flags: TCPSegment.Flags.ack.rawValue
        )
        let ackPacket = IPv4Packet(
            tos: 0, id: 2, ttl: 64, proto: Ethernet.protoTCP,
            src: guest, dst: remote, payload: ack
        )
        stack.handleTCP(packet: ackPacket, segment: try #require(TCPSegment.parse(ack)))

        let receivedHostPayload = try await waitUntil(timeout: .seconds(3)) {
            outputs.withLock { packets in
                packets.compactMap { IPv4Packet.parse($0) }
                    .compactMap { TCPSegment.parse($0.payload)?.payload }
                    .contains(Data("hello-from-host".utf8))
            }
        }
        #expect(receivedHostPayload)
    }

    @Test func translatesOutboundSynBackToTheOriginalPeer() throws {
        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x0101_0101)
        let tcp = makeTCPPacket(
            src: guest, dst: remote, srcPort: 40_000, dstPort: 443,
            seq: 7, flags: TCPSegment.Flags.syn.rawValue
        )
        let packet = IPv4Packet(
            tos: 0, id: 1, ttl: 64, proto: Ethernet.protoTCP,
            src: guest, dst: remote, payload: tcp
        )
        let output = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let signal = DispatchSemaphore(value: 0)
        let stack = GatewaySwiftTCP { _, data in
            output.withLock { $0 = data }
            signal.signal()
        }
        defer { stack.closeAll() }
        stack.handleTCP(packet: packet, segment: try #require(TCPSegment.parse(tcp)))
        #expect(signal.wait(timeout: .now() + 2) == .success)
        let replyData = try #require(output.withLock { $0 })
        let reply = try #require(IPv4Packet.parse(replyData))
        #expect(reply.src == remote)
        #expect(reply.dst == guest)
        #expect(reply.proto == Ethernet.protoTCP)
        #expect(TCPSegment.parse(reply.payload)?.flags.contains(.synAck) == true)
    }

    @Test func bridgesUDPPayloadThroughAMacSocket() throws {
        let listener = try NWListener(using: .udp, on: .any)
        let listenerQueue = DispatchQueue(label: "test.swifttcp.udp")
        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.receiveMessage { data, _, _, _ in
                if data != nil {
                    connection.send(content: Data("hello-udp".utf8), completion: .idempotent)
                }
            }
            connection.start(queue: listenerQueue)
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }
        #expect(listenerReady.wait(timeout: .now() + 1) == .success)
        let hostPort = try #require(listener.port?.rawValue)

        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x7F00_0001)
        let outputs = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let outputSignal = DispatchSemaphore(value: 0)
        let stack = GatewaySwiftTCP { _, data in
            outputs.withLock { $0.append(data) }
            outputSignal.signal()
        }
        defer { stack.closeAll() }

        let datagram = UDPDatagram(srcPort: 40_000, dstPort: hostPort, payload: Data("ping".utf8))
        let encoded = datagram.encode(src: guest, dst: remote)
        let packet = IPv4Packet(
            tos: 0, id: 1, ttl: 64, proto: Ethernet.protoUDP,
            src: guest, dst: remote, payload: encoded
        )
        stack.handleUDP(packet: packet, datagram: datagram)

        var received = false
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !received {
            _ = outputSignal.wait(timeout: .now() + 0.1)
            received = outputs.withLock { packets in
                packets.compactMap { IPv4Packet.parse($0) }
                    .compactMap { UDPDatagram.parse($0.payload)?.payload }
                    .contains(Data("hello-udp".utf8))
            }
        }
        #expect(received)
        let reply = try #require(outputs.withLock { $0.compactMap { IPv4Packet.parse($0) }.last })
        #expect(reply.src == remote)
        #expect(reply.dst == guest)
    }

    @Test func outboundUDPStillWorksAfterIdleTimeout() throws {
        let listener = try NWListener(using: .udp, on: .any)
        let listenerQueue = DispatchQueue(label: "test.swifttcp.udp.idle")
        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
        }
        listener.newConnectionHandler = { connection in
            @Sendable func receive() {
                connection.receiveMessage { data, _, _, _ in
                    if data != nil {
                        connection.send(content: Data("pong".utf8), completion: .idempotent)
                    }
                    receive()
                }
            }
            receive()
            connection.start(queue: listenerQueue)
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }
        #expect(listenerReady.wait(timeout: .now() + 1) == .success)
        let hostPort = try #require(listener.port?.rawValue)

        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x7F00_0001)
        let outputs = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let outputSignal = DispatchSemaphore(value: 0)
        let stack = GatewaySwiftTCP(onGuest: { _, data in
            outputs.withLock { $0.append(data) }
            outputSignal.signal()
        }, udpIdleTimeout: 0.05)
        defer { stack.closeAll() }

        func sendPing() {
            let datagram = UDPDatagram(srcPort: 40_000, dstPort: hostPort, payload: Data("ping".utf8))
            let encoded = datagram.encode(src: guest, dst: remote)
            let packet = IPv4Packet(
                tos: 0, id: 1, ttl: 64, proto: Ethernet.protoUDP,
                src: guest, dst: remote, payload: encoded
            )
            stack.handleUDP(packet: packet, datagram: datagram)
        }
        func waitForPong() -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                _ = outputSignal.wait(timeout: .now() + 0.1)
                if outputs.withLock({ packets in
                    packets.compactMap { IPv4Packet.parse($0) }
                        .compactMap { UDPDatagram.parse($0.payload)?.payload }
                        .contains(Data("pong".utf8))
                }) {
                    return true
                }
            }
            return false
        }

        sendPing()
        #expect(waitForPong())
        outputs.withLock { $0.removeAll() }
        Thread.sleep(forTimeInterval: 0.2)
        sendPing()
        #expect(waitForPong())
    }

    @Test func listenLocalOpensTCPTowardTheGuest() async throws {
        let guest = IPv4Address(0xAC11_0002)
        let outputs = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let stack = GatewaySwiftTCP { _, data in
            outputs.withLock { $0.append(data) }
        }
        defer { stack.closeAll() }

        let port = try await stack.listenLocal(guestIP: guest, guestPort: 80, udp: false)
        #expect(stack.relayCount() == 1)
        let connection = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: UInt16(port))),
            using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "test.swifttcp.inbound"))
        defer { connection.cancel() }

        var packet: IPv4Packet?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, packet == nil {
            packet = outputs.withLock { $0.first }.flatMap { IPv4Packet.parse($0) }
            if packet == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let parsed = try #require(packet)
        #expect(parsed.src == IPv4Address(0xAC11_0001))
        #expect(parsed.dst == guest)
        #expect(TCPSegment.parse(parsed.payload)?.flags.contains(.syn) == true)

        stack.stopListenLocal(guestIP: guest, guestPort: 80, udp: false)
        #expect(stack.relayCount() == 0)
    }

    @Test func hostToGuestThroughput() throws {
        let total = 8 * 1024 * 1024
        let result = try runThroughput(bytes: total, hostSends: true)
        print(String(format: "SwiftTCP host→guest: %.1f Mbps (%d bytes in %.3fs)", result.mbps, total, result.seconds))
        #expect(result.transferred == total)
        #expect(result.mbps > 200, "host→guest throughput regression (\(result.mbps) Mbps)")
    }

    @Test func guestToHostThroughput() throws {
        let total = 8 * 1024 * 1024
        let result = try runThroughput(bytes: total, hostSends: false)
        print(String(format: "SwiftTCP guest→host: %.1f Mbps (%d bytes in %.3fs)", result.mbps, total, result.seconds))
        #expect(result.transferred == total)
        #expect(result.mbps > 200, "guest→host throughput regression (\(result.mbps) Mbps)")
    }
}

// Suspend between checks so the gateway's ingest task can run even on a single worker.
private func waitUntil(timeout: Duration, _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try await clock.sleep(until: min(deadline, clock.now + .milliseconds(5)))
    }
    return true
}

private struct ThroughputResult {
    var transferred: Int
    var seconds: Double
    var mbps: Double
}

private func runThroughput(bytes total: Int, hostSends: Bool) throws -> ThroughputResult {
    let listener = try NWListener(using: .tcp, on: .any)
    let listenerQueue = DispatchQueue(label: "test.swifttcp.throughput")
    let listenerReady = DispatchSemaphore(value: 0)
    let hostReceived = OSAllocatedUnfairLock<Int>(initialState: 0)
    let hostDone = DispatchSemaphore(value: 0)
    let guestReady = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
        if case .ready = state { listenerReady.signal() }
    }
    listener.newConnectionHandler = { connection in
        configureThroughputHost(
            connection, hostSends: hostSends, total: total,
            hostReceived: hostReceived, hostDone: hostDone, guestReady: guestReady,
            queue: listenerQueue
        )
        connection.start(queue: listenerQueue)
    }
    listener.start(queue: listenerQueue)
    defer { listener.cancel() }
    #expect(listenerReady.wait(timeout: .now() + 2) == .success)
    let hostPort = try #require(listener.port?.rawValue)

    let guest = IPv4Address(0xAC11_0002)
    let remote = IPv4Address(0x7F00_0001)
    let session = GuestTCPSession(guest: guest, remote: remote, hostPort: hostPort)
    let stack = GatewaySwiftTCP { _, data in
        session.notePacket(data)
    }
    defer { stack.closeAll() }
    session.forwarder = stack
    try session.handshake()
    guestReady.signal()
    let started = Date()
    let transferred = session.transfer(
        bytes: total, hostSends: hostSends, hostReceived: hostReceived, hostDone: hostDone
    )
    let elapsed = max(Date().timeIntervalSince(started), 0.000_001)
    return ThroughputResult(
        transferred: transferred,
        seconds: elapsed,
        mbps: Double(transferred) * 8.0 / elapsed / 1_000_000.0
    )
}

private func configureThroughputHost(
    _ connection: NWConnection,
    hostSends: Bool,
    total: Int,
    hostReceived: OSAllocatedUnfairLock<Int>,
    hostDone: DispatchSemaphore,
    guestReady: DispatchSemaphore,
    queue: DispatchQueue
) {
    if hostSends {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                queue.async {
                    _ = guestReady.wait(timeout: .now() + 5)
                    connection.send(content: Data(count: total), completion: .contentProcessed { _ in
                        connection.send(content: nil, isComplete: true, completion: .idempotent)
                    })
                }
            }
        }
        return
    }
    @Sendable func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, _ in
            if let data {
                hostReceived.withLock { $0 += data.count }
            }
            if hostReceived.withLock({ $0 }) >= total || complete {
                hostDone.signal()
                return
            }
            receive()
        }
    }
    receive()
}
