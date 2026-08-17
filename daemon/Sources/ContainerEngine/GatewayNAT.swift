import ContainerizationExtras
import Foundation
import Network
import os

/// Userspace TCP/UDP NAT from guest IPv4 packets onto the Mac network stack.
///
/// This terminates the guest's TCP in the daemon and reopens the flow with `NWConnection`,
/// which is what an unprivileged process can do with virtio frames. See ``GatewayForwarder``
/// for the kernel-forwarding alternative this can be swapped for.
final class GatewayNAT: GatewayForwarder, @unchecked Sendable {
    /// Fits a 1500-byte guest MTU with IPv4 + TCP headers.
    private static let mss = 1360
    /// How long an upstream resolver has to answer before the query is dropped.
    private static let dnsTimeout: DispatchTimeInterval = .seconds(5)
    private struct UDPFlow {
        let connection: NWConnection
        let guestIP: ContainerizationExtras.IPv4Address
        let guestPort: UInt16
        let remoteIP: ContainerizationExtras.IPv4Address
        let remotePort: UInt16
    }

    /// Guest → outside. Also carries what a segment back to the guest needs: the peer it appears
    /// to come from and both sequence numbers.
    private struct TCPFlow {
        let connection: NWConnection
        let guestIP: ContainerizationExtras.IPv4Address
        let guestPort: UInt16
        let remoteIP: ContainerizationExtras.IPv4Address
        let remotePort: UInt16
        /// Next sequence we expect from the guest, i.e. what we acknowledge.
        var guestSeq: UInt32
        /// Next sequence we send to the guest.
        var ourSeq: UInt32
    }

    /// Outside → guest, one per accepted connection on a published port. The gateway opens the
    /// connection towards the guest, so it drives the handshake here.
    private struct InboundTCP {
        let connection: NWConnection
        let guestIP: ContainerizationExtras.IPv4Address
        let guestPort: UInt16
        let hostPort: UInt16
        var guestSeq: UInt32
        var ourSeq: UInt32
        /// The guest answered our SYN; before that nothing may be sent.
        var established: Bool
        /// Host bytes that arrived before the guest finished the handshake.
        var pending: Data
        /// The host side is done; send FIN as soon as the guest is established.
        var hostFinished: Bool
    }

    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue = DispatchQueue(label: "io.macker.net.nat")
    private var udp: [String: UDPFlow] = [:]
    private var tcp: [String: TCPFlow] = [:]
    private var inboundTCP: [String: InboundTCP] = [:]
    private var inboundUDP: [String: NWConnection] = [:]
    private var relays: [NWListener] = []
    private var nextHostPort: UInt16 = 40_000
    private var ipID: UInt16 = 1
    private let onGuest: @Sendable (ContainerizationExtras.IPv4Address, Data) -> Void

    init(onGuest: @escaping @Sendable (ContainerizationExtras.IPv4Address, Data) -> Void) {
        self.onGuest = onGuest
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            body()
            return
        }
        queue.sync(execute: body)
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    func handleUDP(packet: IPv4Packet, datagram: UDPDatagram) {
        onQueue {
            self.handleUDPLocked(packet: packet, datagram: datagram)
        }
    }

    private func handleUDPLocked(packet: IPv4Packet, datagram: UDPDatagram) {
        let key = "\(packet.src):\(datagram.srcPort)-\(packet.dst):\(datagram.dstPort)"
        if let flow = udp[key] {
            flow.connection.send(content: datagram.payload, completion: .idempotent)
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(packet.dst.description),
            port: NWEndpoint.Port(rawValue: datagram.dstPort) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .udp)
        let flow = UDPFlow(
            connection: connection,
            guestIP: packet.src,
            guestPort: datagram.srcPort,
            remoteIP: packet.dst,
            remotePort: datagram.dstPort
        )
        udp[key] = flow
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.onQueue { self.udp[key] = nil }
            }
            if case .cancelled = state {
                self.onQueue { self.udp[key] = nil }
            }
        }
        connection.start(queue: queue)
        receiveUDP(key: key, connection: connection)
        connection.send(content: datagram.payload, completion: .idempotent)
    }

    /// Recurse a guest DNS query to a public resolver and answer from the gateway IP.
    /// One connection per query, dropped after the reply or the timeout.
    func forwardDNS(query: Data, guestIP: ContainerizationExtras.IPv4Address, guestPort: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(GatewayDNS.primaryUpstream),
            port: 53
        )
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: query, completion: .idempotent)
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + Self.dnsTimeout) {
            connection.cancel()
        }
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }
            self.queue.async {
                let datagram = UDPDatagram(srcPort: 53, dstPort: guestPort, payload: data)
                let encoded = datagram.encode(src: NetworkGateway.gatewayAddress, dst: guestIP)
                let packet = IPv4Packet(
                    tos: 0,
                    id: self.nextID(),
                    ttl: 64,
                    proto: Ethernet.protoUDP,
                    src: NetworkGateway.gatewayAddress,
                    dst: guestIP,
                    payload: encoded
                )
                self.onGuest(guestIP, packet.encode())
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    private func receiveUDP(key: String, connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.onQueue {
                guard let flow = self.udp[key] else { return }
                if let data {
                    self.replyUDP(flow: flow, payload: data)
                }
                if error == nil {
                    self.receiveUDP(key: key, connection: connection)
                } else {
                    self.udp[key] = nil
                }
            }
        }
    }

    func handleTCP(packet: IPv4Packet, segment: TCPSegment) {
        onQueue {
            self.handleTCPLocked(packet: packet, segment: segment)
        }
    }

    private func handleTCPLocked(packet: IPv4Packet, segment: TCPSegment) {
        let key = Self.outboundKey(packet: packet, segment: segment)

        if segment.flags.contains(.rst) {
            tcp[key]?.connection.cancel()
            tcp[key] = nil
            return
        }

        if segment.flags.contains(.syn), tcp[key] == nil {
            openOutboundTCP(key: key, packet: packet, segment: segment)
            return
        }

        guard var flow = tcp[key] else { return }
        if !segment.payload.isEmpty {
            flow.guestSeq &+= UInt32(segment.payload.count)
            tcp[key] = flow
            flow.connection.send(content: segment.payload, completion: .idempotent)
            sendTCP(flow: flow, flags: .ack, payload: Data())
        }
        if segment.flags.contains(.fin) {
            flow.guestSeq &+= 1
            tcp[key] = flow
            sendTCP(flow: flow, flags: .finAck, payload: Data())
            flow.connection.cancel()
            tcp[key] = nil
        }
    }

    private func openOutboundTCP(key: String, packet: IPv4Packet, segment: TCPSegment) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(packet.dst.description),
            port: NWEndpoint.Port(rawValue: segment.dstPort) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        tcp[key] = TCPFlow(
            connection: connection,
            guestIP: packet.src,
            guestPort: segment.srcPort,
            remoteIP: packet.dst,
            remotePort: segment.dstPort,
            guestSeq: segment.seq &+ 1,
            ourSeq: UInt32.random(in: 1...UInt32.max / 2)
        )
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            self?.tcpReceive(key: key, data: data, isComplete: isComplete, error: error)
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // The guest's SYN is only acknowledged once the real peer accepted.
                self.queue.async {
                    guard var current = self.tcp[key] else { return }
                    self.sendTCP(flow: current, flags: .synAck, payload: Data())
                    current.ourSeq &+= 1
                    self.tcp[key] = current
                }
            case .failed, .cancelled:
                self.queue.async { self.tcp[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private static func outboundKey(packet: IPv4Packet, segment: TCPSegment) -> String {
        "\(packet.src):\(segment.srcPort)-\(packet.dst):\(segment.dstPort)"
    }

    func listenLocal(guestIP: ContainerizationExtras.IPv4Address, guestPort: UInt16, udp: Bool) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters: NWParameters = udp ? .udp : .tcp
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters, on: .any)
                    self.relays.append(listener)
                    listener.newConnectionHandler = { [weak self] incoming in
                        self?.attachInbound(incoming, guestIP: guestIP, guestPort: guestPort, udp: udp)
                    }
                    let pending = OSAllocatedUnfairLock<CheckedContinuation<Int, Error>?>(initialState: continuation)
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            let port = listener.port.map { Int($0.rawValue) } ?? 0
                            pending.withLock { continuation in
                                continuation?.resume(returning: port)
                                continuation = nil
                            }
                        case .failed(let error):
                            pending.withLock { continuation in
                                continuation?.resume(throwing: error)
                                continuation = nil
                            }
                        default:
                            break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func acceptFromGuest(_ packet: IPv4Packet) -> Bool {
        onQueue {
            self.acceptFromGuestLocked(packet)
        }
    }

    private func acceptFromGuestLocked(_ packet: IPv4Packet) -> Bool {
        if packet.proto == Ethernet.protoUDP, let datagram = UDPDatagram.parse(packet.payload) {
            let key = Self.inboundKey(guestIP: packet.src, guestPort: datagram.srcPort, hostPort: datagram.dstPort)
            guard let connection = inboundUDP[key] else { return false }
            connection.send(content: datagram.payload, completion: .idempotent)
            return true
        }
        if packet.proto == Ethernet.protoTCP, let segment = TCPSegment.parse(packet.payload) {
            return acceptInboundTCP(packet: packet, segment: segment)
        }
        return false
    }

    private static func inboundKey(
        guestIP: ContainerizationExtras.IPv4Address,
        guestPort: UInt16,
        hostPort: UInt16
    ) -> String {
        "\(guestIP):\(guestPort)-\(hostPort)"
    }

    func closeAll() {
        onQueue {
            self.udp.values.forEach { $0.connection.cancel() }
            self.tcp.values.forEach { $0.connection.cancel() }
            self.inboundTCP.values.forEach { $0.connection.cancel() }
            self.inboundUDP.values.forEach { $0.cancel() }
            self.relays.forEach { $0.cancel() }
            self.udp.removeAll()
            self.tcp.removeAll()
            self.inboundTCP.removeAll()
            self.inboundUDP.removeAll()
            self.relays.removeAll()
        }
    }

    private func replyUDP(flow: UDPFlow, payload: Data) {
        let datagram = UDPDatagram(srcPort: flow.remotePort, dstPort: flow.guestPort, payload: payload)
        let encoded = datagram.encode(src: flow.remoteIP, dst: flow.guestIP)
        let packet = IPv4Packet(tos: 0, id: nextID(), ttl: 64, proto: Ethernet.protoUDP, src: flow.remoteIP, dst: flow.guestIP, payload: encoded)
        onGuest(flow.guestIP, packet.encode())
    }

    private func tcpReceive(key: String, data: Data?, isComplete: Bool, error: Error?) {
        queue.async { [weak self] in
            guard let self, var flow = self.tcp[key] else { return }
            if let data, !data.isEmpty {
                flow.ourSeq = Self.segment(data, from: flow.ourSeq) { piece, flags, seq in
                    var chunk = flow
                    chunk.ourSeq = seq
                    self.sendTCP(flow: chunk, flags: flags, payload: piece)
                }
                self.tcp[key] = flow
            }
            if isComplete || error != nil {
                self.sendTCP(flow: flow, flags: .finAck, payload: Data())
                flow.connection.cancel()
                self.tcp[key] = nil
                return
            }
            flow.connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, complete, err in
                self.tcpReceive(key: key, data: data, isComplete: complete, error: err)
            }
        }
    }

    /// Splits `data` into MSS-sized segments, pushing on the last one.
    /// Calls `send` with the sequence number each piece must carry; returns the next sequence.
    private static func segment(
        _ data: Data,
        from start: UInt32,
        send: (Data, TCPSegment.Flags, UInt32) -> Void
    ) -> UInt32 {
        var seq = start
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.mss, data.count)
            let chunk = data.subdata(in: offset..<end)
            send(chunk, end == data.count ? .pushAck : .ack, seq)
            seq &+= UInt32(chunk.count)
            offset = end
        }
        return seq
    }

    private func sendTCP(flow: TCPFlow, flags: TCPSegment.Flags, payload: Data) {
        var header = Data(count: TCPSegment.headerLength)
        header[0] = UInt8(truncatingIfNeeded: flow.remotePort >> 8)
        header[1] = UInt8(truncatingIfNeeded: flow.remotePort)
        header[2] = UInt8(truncatingIfNeeded: flow.guestPort >> 8)
        header[3] = UInt8(truncatingIfNeeded: flow.guestPort)
        Self.write32(&header, offset: 4, flow.ourSeq)
        Self.write32(&header, offset: 8, flow.guestSeq)
        header[12] = 0x50 // data offset 5 words, no options
        header[13] = flags.rawValue
        header[14] = 0xff // window: we read as fast as the Mac socket allows
        header[15] = 0xff
        var pseudo = Data()
        pseudo.append(contentsOf: flow.remoteIP.bytes)
        pseudo.append(contentsOf: flow.guestIP.bytes)
        pseudo.append(0)
        pseudo.append(Ethernet.protoTCP)
        let length = TCPSegment.headerLength + payload.count
        pseudo.append(UInt8(truncatingIfNeeded: length >> 8))
        pseudo.append(UInt8(truncatingIfNeeded: length))
        let sum = Ethernet.checksum(pseudo + header + payload)
        let encoded = sum == 0 ? 0xffff : sum
        header[16] = UInt8(truncatingIfNeeded: encoded >> 8)
        header[17] = UInt8(truncatingIfNeeded: encoded)
        let packet = IPv4Packet(
            tos: 0,
            id: nextID(),
            ttl: 64,
            proto: Ethernet.protoTCP,
            src: flow.remoteIP,
            dst: flow.guestIP,
            payload: header + payload
        )
        onGuest(flow.guestIP, packet.encode())
    }

    private func nextID() -> UInt16 {
        ipID &+= 1
        return ipID
    }

    private static func write32(_ data: inout Data, offset: Int, _ value: UInt32) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private func attachInbound(_ incoming: NWConnection, guestIP: ContainerizationExtras.IPv4Address, guestPort: UInt16, udp: Bool) {
        incoming.start(queue: queue)
        if udp {
            attachInboundUDP(incoming, guestIP: guestIP, guestPort: guestPort)
        } else {
            attachInboundTCP(incoming, guestIP: guestIP, guestPort: guestPort)
        }
    }

    private func attachInboundUDP(_ incoming: NWConnection, guestIP: ContainerizationExtras.IPv4Address, guestPort: UInt16) {
        let hostPort = allocHostPort()
        let key = Self.inboundKey(guestIP: guestIP, guestPort: guestPort, hostPort: hostPort)
        inboundUDP[key] = incoming
        receiveInboundUDP(incoming, guestIP: guestIP, guestPort: guestPort, hostPort: hostPort)
    }

    private func receiveInboundUDP(_ incoming: NWConnection, guestIP: ContainerizationExtras.IPv4Address, guestPort: UInt16, hostPort: UInt16) {
        incoming.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                let datagram = UDPDatagram(srcPort: hostPort, dstPort: guestPort, payload: data)
                let encoded = datagram.encode(src: NetworkGateway.gatewayAddress, dst: guestIP)
                let packet = IPv4Packet(
                    tos: 0,
                    id: self.nextID(),
                    ttl: 64,
                    proto: Ethernet.protoUDP,
                    src: NetworkGateway.gatewayAddress,
                    dst: guestIP,
                    payload: encoded
                )
                self.onGuest(guestIP, packet.encode())
            }
            if error == nil {
                self.receiveInboundUDP(incoming, guestIP: guestIP, guestPort: guestPort, hostPort: hostPort)
            }
        }
    }

    private func attachInboundTCP(_ incoming: NWConnection, guestIP: ContainerizationExtras.IPv4Address, guestPort: UInt16) {
        let hostPort = allocHostPort()
        let key = Self.inboundKey(guestIP: guestIP, guestPort: guestPort, hostPort: hostPort)
        var flow = InboundTCP(
            connection: incoming,
            guestIP: guestIP,
            guestPort: guestPort,
            hostPort: hostPort,
            guestSeq: 0,
            ourSeq: UInt32.random(in: 1...UInt32.max / 2),
            established: false,
            pending: Data(),
            hostFinished: false
        )
        inboundTCP[key] = flow
        sendInboundTCP(flow: flow, flags: .syn, payload: Data())
        flow.ourSeq &+= 1
        inboundTCP[key] = flow
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, complete, error in
            self?.inboundHostReceive(key: key, data: data, complete: complete, error: error)
        }
    }

    private func acceptInboundTCP(packet: IPv4Packet, segment: TCPSegment) -> Bool {
        let key = Self.inboundKey(guestIP: packet.src, guestPort: segment.srcPort, hostPort: segment.dstPort)
        guard var flow = inboundTCP[key] else { return false }
        if segment.flags.contains(.rst) {
            flow.connection.cancel()
            inboundTCP[key] = nil
            return true
        }
        if segment.flags.contains(.syn), !flow.established {
            // Guest accepted: only now may host bytes go out, hence the pending buffer.
            flow.guestSeq = segment.seq &+ 1
            flow.established = true
            inboundTCP[key] = flow
            sendInboundTCP(flow: flow, flags: .ack, payload: Data())
            flushInboundHost(key)
            flow = inboundTCP[key] ?? flow
        }
        if !segment.payload.isEmpty, inboundTCP[key] != nil {
            flow.guestSeq &+= UInt32(segment.payload.count)
            inboundTCP[key] = flow
            flow.connection.send(content: segment.payload, completion: .idempotent)
            sendInboundTCP(flow: flow, flags: .ack, payload: Data())
        }
        if segment.flags.contains(.fin), let current = inboundTCP[key] {
            var ended = current
            ended.guestSeq &+= 1
            sendInboundTCP(flow: ended, flags: .finAck, payload: Data())
            ended.connection.cancel()
            inboundTCP[key] = nil
        }
        return true
    }

    private func inboundHostReceive(key: String, data: Data?, complete: Bool, error: Error?) {
        queue.async { [weak self] in
            guard let self, var flow = self.inboundTCP[key] else { return }
            if let data, !data.isEmpty {
                if flow.established {
                    self.sendInboundHostPayload(key: key, data: data)
                    flow = self.inboundTCP[key] ?? flow
                } else {
                    flow.pending.append(data)
                    self.inboundTCP[key] = flow
                }
            }
            if complete || error != nil {
                if flow.established {
                    self.finishInbound(key)
                } else if error != nil {
                    self.sendInboundTCP(flow: flow, flags: .rst, payload: Data())
                    flow.connection.cancel()
                    self.inboundTCP[key] = nil
                } else {
                    flow.hostFinished = true
                    self.inboundTCP[key] = flow
                }
                return
            }
            flow.connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, done, err in
                self.inboundHostReceive(key: key, data: data, complete: done, error: err)
            }
        }
    }

    private func flushInboundHost(_ key: String) {
        guard var flow = inboundTCP[key], flow.established else { return }
        if !flow.pending.isEmpty {
            let pending = flow.pending
            flow.pending = Data()
            inboundTCP[key] = flow
            sendInboundHostPayload(key: key, data: pending)
            flow = inboundTCP[key] ?? flow
        }
        if flow.hostFinished {
            finishInbound(key)
        }
    }

    private func sendInboundHostPayload(key: String, data: Data) {
        guard var flow = inboundTCP[key] else { return }
        flow.ourSeq = Self.segment(data, from: flow.ourSeq) { piece, flags, seq in
            var chunk = flow
            chunk.ourSeq = seq
            self.sendInboundTCP(flow: chunk, flags: flags, payload: piece)
        }
        inboundTCP[key] = flow
    }

    private func finishInbound(_ key: String) {
        guard let flow = inboundTCP[key] else { return }
        sendInboundTCP(flow: flow, flags: .finAck, payload: Data())
        flow.connection.cancel()
        inboundTCP[key] = nil
    }

    private func sendInboundTCP(flow: InboundTCP, flags: TCPSegment.Flags, payload: Data) {
        sendTCP(
            flow: TCPFlow(
                connection: flow.connection,
                guestIP: flow.guestIP,
                guestPort: flow.guestPort,
                remoteIP: NetworkGateway.gatewayAddress,
                remotePort: flow.hostPort,
                guestSeq: flow.guestSeq,
                ourSeq: flow.ourSeq
            ),
            flags: flags,
            payload: payload
        )
    }

    private func allocHostPort() -> UInt16 {
        nextHostPort = nextHostPort == UInt16.max ? 40_000 : nextHostPort &+ 1
        return nextHostPort
    }
}
