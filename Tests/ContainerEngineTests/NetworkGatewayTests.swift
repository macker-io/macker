import ContainerizationExtras
import Foundation
import Network
import Testing
import os
@testable import ContainerEngine

typealias TestIPv4Address = ContainerizationExtras.IPv4Address

@Suite(.serialized)
struct NetworkGatewayTests {
    @Test func ipamSkipsNetworkGatewayAndBroadcast() throws {
        var table = try NetworkIPAM(subnet: "172.17.0.0/16")
        let first = try table.allocate(id: "a")
        #expect(first.description == "172.17.0.2")
        try table.reserve(id: "b", ip: IPv4Address(0xAC11_0003))
        let third = try table.allocate(id: "c")
        #expect(third.description == "172.17.0.4")
        table.release(id: "a")
        let reused = try table.allocate(id: "d")
        #expect(reused.description == "172.17.0.2")
        #expect(throws: EngineError.self) {
            try table.reserve(id: "e", ip: IPv4Address(0xAC11_0003)) // taken by "b"
        }
        #expect(throws: EngineError.self) {
            try table.reserve(id: "e", ip: IPv4Address(0xAC11_0001)) // the gateway
        }
        table.release(id: "b")
        try table.reserve(id: "e", ip: IPv4Address(0xAC11_0003))
        #expect(table.address(for: "e")?.description == "172.17.0.3")
    }

    @Test func ipamHonorsIPRangeAndReservedAddresses() throws {
        var table = try NetworkIPAM(
            subnet: "172.17.0.0/16",
            ipRange: "172.17.0.128/25",
            reserved: [IPv4Address(0xAC11_0080)] // 172.17.0.128
        )
        let first = try table.allocate(id: "a")
        #expect(first.description == "172.17.0.129")
        #expect(throws: EngineError.self) {
            try table.reserve(id: "b", ip: IPv4Address(0xAC11_0002)) // outside ip-range
        }
        #expect(throws: EngineError.self) {
            try table.reserve(id: "b", ip: IPv4Address(0xAC11_0080)) // reserved
        }
        try table.reserve(id: "b", ip: IPv4Address(0xAC11_0082)) // 172.17.0.130
        let next = try table.allocate(id: "c")
        #expect(next.description == "172.17.0.131")
    }

    @Test func ipamRejectsIPRangeOutsideSubnet() {
        #expect(throws: EngineError.self) {
            _ = try NetworkIPAM(subnet: "172.17.0.0/16", ipRange: "10.0.0.0/24")
        }
    }

    @Test func dnsAnswersARecords() throws {
        let ip = IPv4Address(0xAC11_0002)
        var query = Data([0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        query.append(contentsOf: [3, 119, 101, 98, 0, 0, 1, 0, 1]) // web A IN
        let question = try #require(GatewayDNS.parseQuery(query))
        #expect(question.name == "web")
        #expect(question.type == 1)
        let answer = GatewayDNS.answer(id: question.id, name: question.name, address: ip)
        #expect(answer[2] & 0x80 != 0)
        #expect(Array(answer.suffix(4)) == ip.bytes)
        let nodata = GatewayDNS.answer(id: question.id, name: question.name, address: nil)
        #expect(nodata[3] & 0x0f == 0)
        let nx = GatewayDNS.answer(id: question.id, name: question.name, address: nil, nxdomain: true)
        #expect(nx[3] & 0x0f == 3)
        var aaaaQuery = Data([0x00, 0x02, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        aaaaQuery.append(contentsOf: [3, 119, 101, 98, 0, 0, 28, 0, 1]) // web AAAA IN
        let aaaa = try #require(GatewayDNS.parseQuery(aaaaQuery))
        #expect(aaaa.type == GatewayDNS.typeAAAA)
        let aaaaNodata = GatewayDNS.answer(
            id: aaaa.id,
            name: aaaa.name,
            address: nil,
            type: aaaa.type
        )
        #expect(aaaaNodata[3] & 0x0f == 0)
        #expect(Array(aaaaNodata.suffix(4)) == [0, 28, 0, 1])
    }

    @Test func dnsUpstreamsHonorContainerServers() async {
        #expect(GatewayDNS.upstreams(for: []) == GatewayDNS.upstream)
        #expect(GatewayDNS.upstreams(for: ["", "  "]) == GatewayDNS.upstream)
        #expect(GatewayDNS.upstreams(for: [" 8.8.4.4 ", "1.0.0.1"]) == ["8.8.4.4", "1.0.0.1"])

        let gw = NetworkGateway()
        await gw.setDNS(containerID: "c1", nameservers: ["8.8.4.4"])
        #expect(await gw.dnsUpstreams(for: "c1") == ["8.8.4.4"])
        await gw.setDNS(containerID: "c2", nameservers: [])
        #expect(await gw.dnsUpstreams(for: "c2") == GatewayDNS.upstream)
        await gw.detach(containerID: "c1")
        #expect(await gw.dnsUpstreams(for: "c1") == GatewayDNS.upstream)
    }

    @Test func ipv4EncodePacksLargePayloadLength() {
        let src = IPv4Address(0xAC11_0002)
        let dst = IPv4Address(0xC0A8_FF01)
        let packet = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoUDP, src: src, dst: dst, payload: Data(count: 300))
        let encoded = packet.encode()
        #expect(encoded.count == 320)
        #expect(encoded[2] == 0x01)
        #expect(encoded[3] == 0x40)
    }

    @Test func ipv4PeekReadsTupleWithoutReencoding() throws {
        let src = IPv4Address(0xAC11_0002)
        let dst = IPv4Address(0x0101_0101)
        let tcp = Data([
            0x9c, 0x40, 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0
        ])
        let packet = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoTCP, src: src, dst: dst, payload: tcp)
        let encoded = packet.encode()
        let frame = Ethernet.frame(
            dst: MACAddress(0x0A00_2700_0001),
            src: MACAddress(0x0A00_2700_0002),
            type: Ethernet.typeIPv4,
            payload: encoded
        )
        #expect(IPv4Peek.ethernetType(frame) == Ethernet.typeIPv4)
        let datagram = try #require(IPv4Peek.ipv4Datagram(fromEthernet: frame))
        let header = try #require(IPv4Peek.tuple(datagram))
        #expect(header.src == 0xAC11_0002)
        #expect(header.dst == 0x0101_0101)
        #expect(header.proto == Ethernet.protoTCP)
        #expect(header.srcPort == 40_000)
        #expect(header.dstPort == 443)
        #expect(header.tcpFlags & TCPSegment.Flags.syn.rawValue != 0)
    }

    @Test func ethernetRoundTripAndChecksum() throws {
        let src = try MACAddress([0x0A, 0x00, 0x27, 0x00, 0x00, 0x02])
        let dst = NetworkGateway.gatewayMAC
        let payload = Data([1, 2, 3, 4])
        let frame = Ethernet.frame(dst: dst, src: src, type: Ethernet.typeIPv4, payload: payload)
        let parsed = try #require(Ethernet.parse(frame))
        #expect(parsed.src == src)
        #expect(parsed.dst == dst)
        #expect(parsed.type == Ethernet.typeIPv4)
        #expect(parsed.payload == payload)
        #expect(Ethernet.checksum(Data([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7])) == 0x220d)
    }

    @Test func tcpSegmentParsesHeaderFlagsAndPayload() throws {
        var header = Data(count: 20)
        header[0] = 0x1f // src 8080
        header[1] = 0x90
        header[2] = 0x00 // dst 80
        header[3] = 0x50
        header[4] = 0x00 // seq 0x0000_0102
        header[5] = 0x00
        header[6] = 0x01
        header[7] = 0x02
        header[12] = 0x60 // data offset 6 words: 4 bytes of options
        header[13] = TCPSegment.Flags.pushAck.rawValue
        let segment = try #require(TCPSegment.parse(header + Data([9, 9, 9, 9]) + Data([1, 2, 3])))
        #expect(segment.srcPort == 8080)
        #expect(segment.dstPort == 80)
        #expect(segment.seq == 0x0000_0102)
        #expect(segment.flags.contains(.ack))
        #expect(segment.flags.contains(.push))
        #expect(!segment.flags.contains(.syn))
        #expect(segment.payload == Data([1, 2, 3]))
        #expect(TCPSegment.parse(Data(count: 19)) == nil)
        #expect(try #require(TCPSegment.parse(header)).payload.isEmpty)
    }

    @Test func attachmentFactoryStubsFutureDrivers() throws {
        _ = try NetworkAttachmentFactory.make(driver: "bridge")
        _ = try NetworkAttachmentFactory.make(driver: "host")
        _ = try NetworkAttachmentFactory.make(driver: "none")
        #expect(throws: EngineError.self) {
            _ = try NetworkAttachmentFactory.make(driver: "macvlan")
        }
        #expect(throws: EngineError.self) {
            _ = try NetworkAttachmentFactory.make(driver: "ipvlan")
        }
        #expect(throws: EngineError.self) {
            _ = try NetworkAttachmentFactory.make(driver: "container:abc")
        }
    }

    @Test func lwipBridgesTCPPayloadThroughAMacSocket() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let listenerQueue = DispatchQueue(label: "test.lwip.listener")
        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.signal() }
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
        #expect(listenerReady.wait(timeout: .now() + 1) == .success)
        let hostPort = try #require(listener.port?.rawValue)

        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x7F00_0001)
        let outputs = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let outputSignal = DispatchSemaphore(value: 0)
        let stack = try #require(GatewayLwIP { _, data in
            outputs.withLock { $0.append(data) }
            outputSignal.signal()
        })
        defer { stack.closeAll() }

        let syn = makeTCPPacket(src: guest, dst: remote, srcPort: 40_000, dstPort: hostPort,
                                seq: 7, flags: TCPSegment.Flags.syn.rawValue)
        let synPacket = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoTCP,
                                   src: guest, dst: remote, payload: syn)
        stack.handleTCP(packet: synPacket, segment: try #require(TCPSegment.parse(syn)))
        #expect(outputSignal.wait(timeout: .now() + 1) == .success)
        let synAckData = try #require(outputs.withLock { $0.first })
        let synAckPacket = try #require(IPv4Packet.parse(synAckData))
        let synAckSegment = try #require(TCPSegment.parse(synAckPacket.payload))
        let ack = makeTCPPacket(src: guest, dst: remote, srcPort: 40_000, dstPort: hostPort,
                                seq: 8, ack: synAckSegment.seq &+ 1, flags: TCPSegment.Flags.ack.rawValue)
        let ackPacket = IPv4Packet(tos: 0, id: 2, ttl: 64, proto: Ethernet.protoTCP,
                                   src: guest, dst: remote, payload: ack)
        stack.handleTCP(packet: ackPacket, segment: try #require(TCPSegment.parse(ack)))

        var receivedHostPayload = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !receivedHostPayload {
            _ = outputSignal.wait(timeout: .now() + 0.1)
            receivedHostPayload = outputs.withLock { packets in
                packets.compactMap { IPv4Packet.parse($0) }
                    .compactMap { TCPSegment.parse($0.payload)?.payload }
                    .contains(Data("hello-from-host".utf8))
            }
        }
        #expect(receivedHostPayload)
    }

    @Test func lwipTranslatesOutboundSynBackToTheOriginalPeer() throws {
        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x0101_0101)
        let tcp = makeTCPPacket(src: guest, dst: remote, srcPort: 40_000, dstPort: 443,
                                seq: 7, flags: TCPSegment.Flags.syn.rawValue)
        let packet = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoTCP,
                                src: guest, dst: remote, payload: tcp)
        let output = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let signal = DispatchSemaphore(value: 0)
        let stack = try #require(GatewayLwIP { _, data in
            output.withLock { $0 = data }
            signal.signal()
        })
        defer { stack.closeAll() }
        let parsed = try #require(TCPSegment.parse(tcp))
        stack.handleTCP(packet: packet, segment: parsed)
        #expect(signal.wait(timeout: .now() + 1) == .success)
        let replyData = try #require(output.withLock { $0 })
        let reply = try #require(IPv4Packet.parse(replyData))
        #expect(reply.src == remote)
        #expect(reply.dst == guest)
        #expect(reply.proto == Ethernet.protoTCP)
        #expect(TCPSegment.parse(reply.payload)?.flags.contains(.synAck) == true)
    }

    @Test func lwipBridgesUDPPayloadThroughAMacSocket() throws {
        let listener = try NWListener(using: .udp, on: .any)
        let listenerQueue = DispatchQueue(label: "test.lwip.udp")
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
        let stack = try #require(GatewayLwIP { _, data in
            outputs.withLock { $0.append(data) }
            outputSignal.signal()
        })
        defer { stack.closeAll() }

        let datagram = UDPDatagram(srcPort: 40_000, dstPort: hostPort, payload: Data("ping".utf8))
        let encoded = datagram.encode(src: guest, dst: remote)
        let packet = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoUDP,
                                src: guest, dst: remote, payload: encoded)
        stack.handleUDP(packet: packet, datagram: datagram)

        var received = false
        let deadline = Date().addingTimeInterval(2)
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

    @Test func lwipDropsIdleOutboundUDPFlows() throws {
        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x7F00_0001)
        let created = GatewayLwIP(
            onGuest: { _, _ in },
            udpIdleTimeout: 0.05,
            udpSweepInterval: 0.05
        )
        let stack = try #require(created)
        defer { stack.closeAll() }
        let datagram = UDPDatagram(srcPort: 40_000, dstPort: 9, payload: Data("x".utf8))
        let encoded = datagram.encode(src: guest, dst: remote)
        let packet = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoUDP,
                                src: guest, dst: remote, payload: encoded)
        stack.handleUDP(packet: packet, datagram: datagram)

        var sawFlow = false
        let createdDeadline = Date().addingTimeInterval(1)
        while Date() < createdDeadline, !sawFlow {
            sawFlow = stack.udpFlowCount() > 0
            if !sawFlow { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(sawFlow)

        var gone = false
        let idleDeadline = Date().addingTimeInterval(1)
        while Date() < idleDeadline, !gone {
            gone = stack.udpFlowCount() == 0
            if !gone { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(gone)
    }

    @Test func lwipListenLocalOpensTCPTowardTheGuest() async throws {
        let guest = IPv4Address(0xAC11_0002)
        let outputs = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let stack = try #require(GatewayLwIP { _, data in
            outputs.withLock { $0.append(data) }
        })
        defer { stack.closeAll() }

        let port = try await stack.listenLocal(guestIP: guest, guestPort: 80, udp: false)
        #expect(stack.relayCount() == 1)
        let connection = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: UInt16(port))),
            using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "test.lwip.inbound"))
        defer { connection.cancel() }

        var packet: IPv4Packet?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, packet == nil {
            packet = outputs.withLock { $0.first }.flatMap { IPv4Packet.parse($0) }
            if packet == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let parsed = try #require(packet)
        #expect(parsed.src == NetworkGateway.gatewayAddress)
        #expect(parsed.dst == guest)
        #expect(TCPSegment.parse(parsed.payload)?.flags.contains(.syn) == true)

        stack.stopListenLocal(guestIP: guest, guestPort: 80, udp: false)
        #expect(stack.relayCount() == 0)
    }

    @Test func lwipHostToGuestThroughput() throws {
        let total = 8 * 1024 * 1024
        let result = try runLwIPThroughput(bytes: total, hostSends: true)
        print(String(format: "lwIP host→guest: %.1f Mbps (%d bytes in %.3fs)", result.mbps, total, result.seconds))
        #expect(result.transferred == total)
        #expect(result.mbps > 200, "host→guest throughput regression (\(result.mbps) Mbps)")
    }

    @Test func lwipGuestToHostThroughput() throws {
        let total = 8 * 1024 * 1024
        let result = try runLwIPThroughput(bytes: total, hostSends: false)
        print(String(format: "lwIP guest→host: %.1f Mbps (%d bytes in %.3fs)", result.mbps, total, result.seconds))
        #expect(result.transferred == total)
        #expect(result.mbps > 200, "guest→host throughput regression (\(result.mbps) Mbps)")
    }

    private struct ThroughputResult {
        var transferred: Int
        var seconds: Double
        var mbps: Double
    }

    private func runLwIPThroughput(bytes total: Int, hostSends: Bool) throws -> ThroughputResult {
        let listener = try NWListener(using: .tcp, on: .any)
        let listenerQueue = DispatchQueue(label: "test.lwip.throughput")
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
                            connection.send(content: Data(count: total), completion: .contentProcessed { _ in
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
                        if hostReceived.withLock({ $0 }) >= total || complete {
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

        let guest = IPv4Address(0xAC11_0002)
        let remote = IPv4Address(0x7F00_0001)
        let packets = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let packetSignal = DispatchSemaphore(value: 0)
        let stack = try #require(GatewayLwIP { _, data in
            packets.withLock { $0.append(data) }
            packetSignal.signal()
        })
        defer { stack.closeAll() }

        let isn: UInt32 = 1_000
        let srcPort: UInt16 = 41_000
        var sndNxt = isn
        var rcvNxt: UInt32 = 0
        var peerWindow: UInt32 = 65_535
        var sndUna = isn
        var ipID: UInt16 = 1
        var received = 0
        var payloadSent = 0

        func sendSegment(seq: UInt32, ack: UInt32, flags: UInt8, payload: Data = Data(),
                         options: Data = Data()) {
            let tcp = makeTCPPacket(
                src: guest, dst: remote, srcPort: srcPort, dstPort: hostPort,
                seq: seq, ack: ack, flags: flags, options: options, payload: payload
            )
            let packet = IPv4Packet(
                tos: 0, id: ipID, ttl: 64, proto: Ethernet.protoTCP,
                src: guest, dst: remote, payload: tcp
            )
            ipID &+= 1
            guard let segment = TCPSegment.parse(tcp) else { return }
            stack.handleTCP(packet: packet, segment: segment)
        }

        sendSegment(
            seq: isn, ack: 0, flags: TCPSegment.Flags.syn.rawValue,
            options: Data([0x02, 0x04, 0x10, 0x00, 0x01, 0x03, 0x03, 0x07]) // MSS 4096, NOP, WS 7
        )
        sndNxt &+= 1
        sndUna &+= 1

        func drainPackets(timeout: TimeInterval) -> [(segment: TCPSegment, tcp: Data)] {
            let queued = packets.withLock { $0.count }
            if queued == 0, timeout > 0 {
                _ = packetSignal.wait(timeout: .now() + timeout)
            }
            let batch = packets.withLock { value -> [Data] in
                let copy = value
                value.removeAll(keepingCapacity: true)
                return copy
            }
            return batch.compactMap { ip -> (TCPSegment, Data)? in
                guard let packet = IPv4Packet.parse(ip), let segment = TCPSegment.parse(packet.payload) else {
                    return nil
                }
                return (segment, packet.payload)
            }
        }

        var sndWndScale: UInt32 = 0
        let handshakeDeadline = Date().addingTimeInterval(2)
        var established = false
        while Date() < handshakeDeadline, !established {
            for item in drainPackets(timeout: 0.05) {
                if item.segment.flags.contains(.syn) {
                    rcvNxt = item.segment.seq &+ 1
                    if let scale = tcpWindowScale(item.tcp) {
                        sndWndScale = UInt32(scale)
                    }
                    peerWindow = UInt32(item.segment.window) << sndWndScale
                    sendSegment(seq: sndNxt, ack: rcvNxt, flags: TCPSegment.Flags.ack.rawValue)
                    established = true
                }
            }
        }
        #expect(established)
        guestReady.signal()

        let started = Date()
        let deadline = started.addingTimeInterval(15)
        let mss = 4096

        func pumpGuestPayload() {
            guard !hostSends else { return }
            while payloadSent < total {
                let inFlight = Int(sndNxt &- sndUna)
                let room = max(0, Int(peerWindow) - inFlight)
                let chunk = min(mss, total - payloadSent, room)
                if chunk <= 0 { break }
                let slice = Data(count: chunk)
                sendSegment(
                    seq: sndNxt, ack: rcvNxt,
                    flags: TCPSegment.Flags.pushAck.rawValue,
                    payload: slice
                )
                sndNxt &+= UInt32(chunk)
                payloadSent += chunk
            }
        }

        pumpGuestPayload()
        while Date() < deadline {
            if hostSends, received >= total { break }
            if !hostSends, hostReceived.withLock({ $0 }) >= total { break }
            let inFlight = Int(sndNxt &- sndUna)
            let canSend = !hostSends && payloadSent < total && Int(peerWindow) > inFlight
            for item in drainPackets(timeout: canSend ? 0 : 0.002) {
                let segment = item.segment
                if segment.flags.contains(.rst) { break }
                if segment.flags.contains(.ack) {
                    let ack = segment.ack
                    if ack &- sndUna < 0x8000_0000 {
                        sndUna = ack
                    }
                    peerWindow = UInt32(segment.window) << sndWndScale
                }
                if !segment.payload.isEmpty {
                    if hostSends, segment.seq == rcvNxt, received < total {
                        let n = min(segment.payload.count, total - received)
                        received += n
                        rcvNxt &+= UInt32(segment.payload.count)
                    }
                    sendSegment(seq: sndNxt, ack: rcvNxt, flags: TCPSegment.Flags.ack.rawValue)
                }
                if segment.flags.contains(.fin) {
                    rcvNxt = segment.seq &+ 1
                    sendSegment(seq: sndNxt, ack: rcvNxt, flags: TCPSegment.Flags.ack.rawValue)
                }
            }
            pumpGuestPayload()
        }

        if !hostSends {
            _ = hostDone.wait(timeout: .now() + 1)
        }

        let elapsed = max(Date().timeIntervalSince(started), 0.000_001)
        let transferred = hostSends ? received : hostReceived.withLock { $0 }
        return ThroughputResult(
            transferred: transferred,
            seconds: elapsed,
            mbps: Double(transferred) * 8.0 / elapsed / 1_000_000.0
        )
    }


    private func tcpWindowScale(_ tcp: Data) -> UInt8? {
        guard tcp.count >= 20 else { return nil }
        let header = Int(tcp[12] >> 4) * 4
        var index = 20
        while index + 2 < min(header, tcp.count) {
            switch tcp[index] {
            case 0:
                return nil
            case 1:
                index += 1
            case 3:
                if tcp[index + 1] == 3 { return tcp[index + 2] }
                index += max(Int(tcp[index + 1]), 2)
            default:
                index += max(Int(tcp[index + 1]), 2)
            }
        }
        return nil
    }

    private func makeTCPPacket(src: TestIPv4Address, dst: TestIPv4Address, srcPort: UInt16,
                               dstPort: UInt16, seq: UInt32, ack: UInt32 = 0,
                               flags: UInt8, options: Data = Data(), payload: Data = Data()) -> Data {
        var header = Data(count: TCPSegment.headerLength)
        header[0] = UInt8(truncatingIfNeeded: srcPort >> 8)
        header[1] = UInt8(truncatingIfNeeded: srcPort)
        header[2] = UInt8(truncatingIfNeeded: dstPort >> 8)
        header[3] = UInt8(truncatingIfNeeded: dstPort)
        header[4] = UInt8(truncatingIfNeeded: seq >> 24)
        header[5] = UInt8(truncatingIfNeeded: seq >> 16)
        header[6] = UInt8(truncatingIfNeeded: seq >> 8)
        header[7] = UInt8(truncatingIfNeeded: seq)
        header[8] = UInt8(truncatingIfNeeded: ack >> 24)
        header[9] = UInt8(truncatingIfNeeded: ack >> 16)
        header[10] = UInt8(truncatingIfNeeded: ack >> 8)
        header[11] = UInt8(truncatingIfNeeded: ack)
        let offset = TCPSegment.headerLength + options.count
        header[12] = UInt8((offset / 4) << 4)
        header[13] = flags
        header[14] = 0xff
        header[15] = 0xff
        let transport = header + options + payload
        var pseudo = Data()
        pseudo.append(contentsOf: src.bytes)
        pseudo.append(contentsOf: dst.bytes)
        pseudo.append(0)
        pseudo.append(Ethernet.protoTCP)
        pseudo.append(UInt8(truncatingIfNeeded: transport.count >> 8))
        pseudo.append(UInt8(truncatingIfNeeded: transport.count))
        let sum = Ethernet.checksum(pseudo + transport)
        header[16] = UInt8(truncatingIfNeeded: sum >> 8)
        header[17] = UInt8(truncatingIfNeeded: sum)
        return header + options + payload
    }

    @Test func portPublishTargetUsesLocalhostRelayWithoutHostRoute() async throws {
        let gateway = NetworkGateway()
        #expect(await gateway.utunReady == false)
        let guest = IPv4Address(0xAC11_0002)
        let target = try await gateway.portPublishTarget(guestIP: guest, guestPort: 80, udp: false)
        #expect(target.ip == "127.0.0.1")
        #expect(target.port > 0)
        await gateway.stopPortRelay(guestIP: guest, guestPort: 80, udp: false)
        await gateway.shutdown()
    }

    @Test func dataplaneForwardsSameNetworkWithoutLwIP() throws {
        let net = EngineNetwork(
            id: "net-a",
            name: "bridge",
            driver: "bridge",
            scope: "local",
            created: Date(),
            labels: [:],
            subnet: "172.17.0.0/16",
            gateway: "172.17.0.1",
            internalNetwork: false,
            builtin: true
        )
        let srcIP = IPv4Address(0xAC11_0002)
        let dstIP = IPv4Address(0xAC11_0003)
        let srcLink = try FileHandleLink(
            containerID: "src",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: NetworkGateway.gatewayAddress,
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dstLink = try FileHandleLink(
            containerID: "dst",
            ipv4: try CIDRv4("172.17.0.3/32"),
            gateway: NetworkGateway.gatewayAddress,
            mac: MACAddress(0x0A00_2700_0003)
        )
        let dataplane = BridgeDataplane()
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "src",
                    containerName: "src",
                    hostname: "src",
                    networkID: net.id,
                    networkName: net.name,
                    ip: srcIP,
                    aliases: [],
                    internalNetwork: false
                ),
                NetworkGateway.Record(
                    containerID: "dst",
                    containerName: "dst",
                    hostname: "dst",
                    networkID: net.id,
                    networkName: net.name,
                    ip: dstIP,
                    aliases: [],
                    internalNetwork: false
                ),
            ],
            dnsUpstreams: [:],
            links: ["src": srcLink, "dst": dstLink],
            forwarder: nil
        )
        let payload = Data("same-net".utf8)
        let datagram = UDPDatagram(srcPort: 40_000, dstPort: 9, payload: payload)
        let packet = IPv4Packet(
            tos: 0,
            id: 1,
            ttl: 64,
            proto: Ethernet.protoUDP,
            src: srcIP,
            dst: dstIP,
            payload: datagram.encode(src: srcIP, dst: dstIP)
        )
        let frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeIPv4,
            payload: packet.encode()
        )
        frame.withUnsafeBytes { dataplane.handleFrame(containerID: "src", frame: $0) }
        let received = try #require(dstLink.recvGuest())
        #expect(IPv4Peek.ethernetType(received) == Ethernet.typeIPv4)
        let ip = try #require(IPv4Peek.ipv4Datagram(fromEthernet: received).flatMap(IPv4Packet.parse))
        #expect(ip.src == srcIP)
        #expect(ip.dst == dstIP)
        #expect(UDPDatagram.parse(ip.payload)?.payload == payload)
    }

    @Test func dataplaneDropsCrossNetworkForward() throws {
        let srcIP = IPv4Address(0xAC11_0002)
        let dstIP = IPv4Address(0xAC12_0002)
        let srcLink = try FileHandleLink(
            containerID: "web",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: NetworkGateway.gatewayAddress,
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dstLink = try FileHandleLink(
            containerID: "db",
            ipv4: try CIDRv4("172.18.0.2/32"),
            gateway: NetworkGateway.gatewayAddress,
            mac: MACAddress(0x0A00_2700_0003)
        )
        let dataplane = BridgeDataplane()
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "web",
                    containerName: "web",
                    hostname: "web",
                    networkID: "net-a",
                    networkName: "bridge",
                    ip: srcIP,
                    aliases: [],
                    internalNetwork: false
                ),
                NetworkGateway.Record(
                    containerID: "db",
                    containerName: "db",
                    hostname: "db",
                    networkID: "net-b",
                    networkName: "backend",
                    ip: dstIP,
                    aliases: [],
                    internalNetwork: true
                ),
            ],
            dnsUpstreams: [:],
            links: ["web": srcLink, "db": dstLink],
            forwarder: nil
        )
        let datagram = UDPDatagram(srcPort: 40_000, dstPort: 9, payload: Data("x".utf8))
        let packet = IPv4Packet(
            tos: 0,
            id: 1,
            ttl: 64,
            proto: Ethernet.protoUDP,
            src: srcIP,
            dst: dstIP,
            payload: datagram.encode(src: srcIP, dst: dstIP)
        )
        let frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeIPv4,
            payload: packet.encode()
        )
        frame.withUnsafeBytes { dataplane.handleFrame(containerID: "web", frame: $0) }
        #expect(dstLink.recvGuest() == nil)
    }

    @Test func gatewayAclAndDnsStayOnTheSameNetwork() async throws {
        let gateway = NetworkGateway()
        let bridge = EngineNetwork(
            id: "net-a",
            name: "bridge",
            driver: "bridge",
            scope: "local",
            created: Date(),
            labels: [:],
            subnet: "172.17.0.0/16",
            gateway: "172.17.0.1",
            internalNetwork: false,
            builtin: true
        )
        let backend = EngineNetwork(
            id: "net-b",
            name: "backend",
            driver: "bridge",
            scope: "local",
            created: Date(),
            labels: [:],
            subnet: "172.18.0.0/16",
            gateway: "172.18.0.1",
            internalNetwork: true,
            builtin: false
        )
        await gateway.registerNetwork(bridge)
        await gateway.registerNetwork(backend)
        let web = try await gateway.allocate(bridge.id, key: "web:net-a")
        let db = try await gateway.allocate(backend.id, key: "db:net-b")
        await gateway.bind(
            containerID: "web",
            containerName: "web",
            hostname: "web",
            network: bridge,
            ip: web,
            aliases: ["www"]
        )
        await gateway.bind(
            containerID: "db",
            containerName: "db",
            hostname: "db",
            network: backend,
            ip: db,
            aliases: []
        )
        #expect(await gateway.canForward(src: web, dst: db) == false)
        #expect(await gateway.allowsOutbound(src: web))
        #expect(await gateway.allowsOutbound(src: db) == false)
        #expect(await gateway.lookup(name: "web", from: web) == web)
        #expect(await gateway.lookup(name: "www", from: web) == web)
        #expect(await gateway.lookup(name: "db", from: web) == nil)
        #expect(await gateway.lookup(name: "db", from: db) == db)
        let webOnBackend = try await gateway.allocate(backend.id, key: "web:net-b")
        await gateway.bind(
            containerID: "web",
            containerName: "web",
            hostname: "web",
            network: backend,
            ip: webOnBackend,
            aliases: []
        )
        #expect(await gateway.lookup(name: "db", from: web) == db)
        #expect(await gateway.canForward(src: web, dst: db))
        #expect(NetworkGateway.gatewayAddress.description == "192.168.255.1")
    }
}
