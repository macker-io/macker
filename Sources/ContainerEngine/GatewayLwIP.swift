import ContainerizationExtras
import Foundation
import LwIPPort
import Network
import os

typealias GuestIPv4Address = ContainerizationExtras.IPv4Address

/// Userspace bridge between lwIP's guest-facing TCP/UDP state machines and Mac sockets.
///
/// lwIP only sees a translated, point-to-point IPv4 interface. Its link output is rewritten
/// back to the original remote endpoint before it is delivered to the guest. Host sockets carry
/// application payloads; they are deliberately not used as a second TCP implementation.
///
/// I/O stays on a dedicated queue (gvisor-tap-vsock / netstack style): large socket reads,
/// coalesced guest→host DATA, TCP_NODELAY, and backpressure instead of dropping when the
/// stack's send buffer is full.
final class GatewayLwIP: GatewayForwarder, @unchecked Sendable {
    private static let maxPending = 1024 * 1024
    private static let receiveChunk = 256 * 1024

    private struct FlowKey: Hashable {
        let guestIP: UInt32
        let remoteIP: UInt32
        let guestPort: UInt16
        let remotePort: UInt16
    }

    private struct TCPFlow {
        let id: UInt32
        let key: FlowKey
        let guestIP: GuestIPv4Address
        let guestPort: UInt16
        let remoteIP: GuestIPv4Address
        let remotePort: UInt16
        var connection: NWConnection?
        var pendingToHost = Data()
        var connected = false
        var inbound: Bool
        var hostFinished = false
        var receivePaused = false
    }

    private struct UDPFlow {
        let id: UInt32
        let key: FlowKey
        let guestIP: GuestIPv4Address
        let guestPort: UInt16
        let flowPort: UInt16
        var connection: NWConnection?
        var inbound: Bool
        var lastActivity = Date()
    }

    private struct LocalRelay {
        let listener: NWListener
        let guestIP: GuestIPv4Address
        let guestPort: UInt16
        let udp: Bool
    }

    private static let queueKey = DispatchSpecificKey<UInt8>()
    private let queue = DispatchQueue(label: "io.macker.net.lwip")
    private var core: OpaquePointer?
    private var tcp: [UInt32: TCPFlow] = [:]
    private var tcpByEndpoint: [FlowKey: UInt32] = [:]
    private var udp: [UInt32: UDPFlow] = [:]
    private var udpByEndpoint: [FlowKey: UInt32] = [:]
    private var relays: [LocalRelay] = []
    private var nextID: UInt32 = 1
    private var nextRelayPort: UInt16 = 50_000
    private var tcpInputBatch: [(id: UInt32, packet: Data)] = []
    private let onGuest: @Sendable (GuestIPv4Address, Data) -> Void
    private let udpIdleTimeout: TimeInterval
    private var sweep: DispatchSourceTimer?

    init?(
        onGuest: @escaping @Sendable (GuestIPv4Address, Data) -> Void,
        udpIdleTimeout: TimeInterval = 60,
        udpSweepInterval: TimeInterval = 10
    ) {
        self.onGuest = onGuest
        self.udpIdleTimeout = udpIdleTimeout
        queue.setSpecific(key: Self.queueKey, value: 1)
        self.core = nil
        guard let core = macker_lwip_create(
            Self.outputCallback,
            Self.eventCallback,
            Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }
        self.core = core
        if udpSweepInterval > 0 {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + udpSweepInterval,
                repeating: udpSweepInterval
            )
            timer.setEventHandler { [weak self] in
                self?.sweepIdleUDP()
            }
            timer.resume()
            self.sweep = timer
        }
    }

    deinit {
        closeAll()
    }

    func handleUDP(packet: IPv4Packet, datagram: UDPDatagram) {
        ingestIPv4(packet.encode())
    }

    func handleTCP(packet: IPv4Packet, segment: TCPSegment) {
        ingestIPv4(packet.encode())
    }

    func ingestIPv4(_ packet: Data) {
        enqueue { [self] in ingestIPv4Locked(packet) }
    }

    func acceptIPv4(_ packet: Data) -> Bool {
        onQueue { acceptIPv4Locked(packet) }
    }

    func acceptFromGuest(_ packet: IPv4Packet) -> Bool {
        acceptIPv4(packet.encode())
    }

    func forwardDNS(query: Data, guestIP: GuestIPv4Address, guestPort: UInt16, upstreams: [String]) {
        // DNS recursion remains in NetworkGateway's existing small UDP path.
        let server = upstreams.first ?? GatewayDNS.primaryUpstream
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(server), port: 53)
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { state in
            if case .ready = state { connection.send(content: query, completion: .idempotent) }
            if case .failed = state { connection.cancel() }
        }
        queue.asyncAfter(deadline: .now() + .seconds(5)) {
            connection.cancel()
        }
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            self.onQueue {
                let datagram = UDPDatagram(srcPort: 53, dstPort: guestPort, payload: data)
                let payload = datagram.encode(src: NetworkGateway.gatewayAddress, dst: guestIP)
                let packet = IPv4Packet(tos: 0, id: 0, ttl: 64, proto: Ethernet.protoUDP,
                                        src: NetworkGateway.gatewayAddress, dst: guestIP, payload: payload)
                self.onGuest(guestIP, packet.encode())
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    func listenLocal(guestIP: GuestIPv4Address, guestPort: UInt16, udp: Bool) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            onQueue {
                do {
                    let parameters = udp ? NWParameters.udp : Self.tcpParameters()
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters, on: .any)
                    listener.newConnectionHandler = { [weak self] incoming in
                        guard let self else { return }
                        self.enqueue { [self] in
                            self.attachInbound(incoming, guestIP: guestIP, guestPort: guestPort, udp: udp)
                        }
                    }
                    let pending = OSAllocatedUnfairLock<CheckedContinuation<Int, Error>?>(initialState: continuation)
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            self?.enqueue { [weak self] in
                                self?.relays.append(
                                    LocalRelay(listener: listener, guestIP: guestIP, guestPort: guestPort, udp: udp)
                                )
                            }
                            pending.withLock { value in
                                value?.resume(returning: Int(listener.port?.rawValue ?? 0))
                                value = nil
                            }
                        case .failed(let error):
                            listener.cancel()
                            pending.withLock { value in
                                value?.resume(throwing: error)
                                value = nil
                            }
                        case .cancelled:
                            pending.withLock { value in
                                value?.resume(throwing: EngineError.conflict("port relay cancelled"))
                                value = nil
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

    private func ingestIPv4Locked(_ packet: Data) {
        guard let header = IPv4Peek.tuple(packet) else { return }
        switch header.proto {
        case Ethernet.protoTCP:
            ingestTCP(packet, header)
        case Ethernet.protoUDP:
            ingestUDP(packet, header)
        default:
            break
        }
    }

    private func ingestTCP(_ packet: Data, _ header: IPv4Peek.Tuple) {
        let key = FlowKey(
            guestIP: header.src, remoteIP: header.dst,
            guestPort: header.srcPort, remotePort: header.dstPort
        )
        if header.tcpFlags & TCPSegment.Flags.rst.rawValue != 0 {
            if let id = tcpByEndpoint[key] { closeTCP(id: id) }
            return
        }
        if let id = tcpByEndpoint[key] {
            enqueueTCPInput(id: id, packet: packet)
            flushTCPInput()
            return
        }
        guard header.tcpFlags & TCPSegment.Flags.syn.rawValue != 0 else { return }
        let src = GuestIPv4Address(header.src)
        let dst = GuestIPv4Address(header.dst)
        let id = allocateID()
        let connection = NWConnection(
            to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(dst.description),
                port: NWEndpoint.Port(rawValue: header.dstPort) ?? .any
            ),
            using: Self.tcpParameters()
        )
        tcp[id] = TCPFlow(
            id: id, key: key, guestIP: src, guestPort: header.srcPort,
            remoteIP: dst, remotePort: header.dstPort,
            connection: connection, inbound: false
        )
        tcpByEndpoint[key] = id
        configureTCP(connection, id: id)
        connection.start(queue: queue)
        guard let core else { return }
        let result = packet.withUnsafeBytes { bytes in
            macker_lwip_tcp_outbound_start(
                core, id, header.dst, header.dstPort,
                header.src, header.srcPort,
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count
            )
        }
        if result != 0 { closeTCP(id: id) }
    }

    private func ingestUDP(_ packet: Data, _ header: IPv4Peek.Tuple) {
        let key = FlowKey(
            guestIP: header.src, remoteIP: header.dst,
            guestPort: header.srcPort, remotePort: header.dstPort
        )
        if let id = udpByEndpoint[key] {
            touchUDP(id: id)
            sendUDPToCore(id: id, packet: packet)
            return
        }
        let src = GuestIPv4Address(header.src)
        let dst = GuestIPv4Address(header.dst)
        let id = allocateID()
        let connection = NWConnection(
            to: NWEndpoint.hostPort(
                host: NWEndpoint.Host(dst.description),
                port: NWEndpoint.Port(rawValue: header.dstPort) ?? .any
            ),
            using: .udp
        )
        udp[id] = UDPFlow(
            id: id, key: key, guestIP: src, guestPort: header.srcPort,
            flowPort: header.dstPort, connection: connection, inbound: false
        )
        udpByEndpoint[key] = id
        configureOutboundUDP(connection, id: id)
        connection.start(queue: queue)
        sendUDPToCore(id: id, packet: packet, first: true, remoteIP: dst, remotePort: header.dstPort)
    }

    private func acceptIPv4Locked(_ packet: Data) -> Bool {
        guard let header = IPv4Peek.tuple(packet) else { return false }
        let key = FlowKey(
            guestIP: header.src,
            remoteIP: Self.address(NetworkGateway.gatewayAddress),
            guestPort: header.srcPort,
            remotePort: header.dstPort
        )
        if header.proto == Ethernet.protoTCP, let id = tcpByEndpoint[key] {
            enqueueTCPInput(id: id, packet: packet)
            flushTCPInput()
            return true
        }
        if header.proto == Ethernet.protoUDP, let id = udpByEndpoint[key] {
            sendUDPToCore(id: id, packet: packet)
            return true
        }
        return false
    }

    func stopListenLocal(guestIP: GuestIPv4Address, guestPort: UInt16, udp: Bool) {
        onQueue {
            let removed = relays.filter { $0.guestIP == guestIP && $0.guestPort == guestPort && $0.udp == udp }
            relays.removeAll { $0.guestIP == guestIP && $0.guestPort == guestPort && $0.udp == udp }
            removed.forEach { $0.listener.cancel() }
            if udp {
                let ids = self.udp.values.filter { $0.inbound && $0.guestIP == guestIP && $0.guestPort == guestPort }.map(\.id)
                ids.forEach { closeUDP(id: $0) }
            } else {
                let ids = self.tcp.values.filter { $0.inbound && $0.guestIP == guestIP && $0.guestPort == guestPort }.map(\.id)
                ids.forEach { closeTCP(id: $0) }
            }
        }
    }

    func closeAll() {
        onQueue {
            sweep?.cancel()
            sweep = nil
            tcp.values.forEach { $0.connection?.cancel() }
            udp.values.forEach { $0.connection?.cancel() }
            relays.forEach { $0.listener.cancel() }
            tcp.removeAll()
            tcpByEndpoint.removeAll()
            tcpInputBatch.removeAll()
            udp.removeAll()
            udpByEndpoint.removeAll()
            relays.removeAll()
            if let core {
                macker_lwip_destroy(core)
                self.core = nil
            }
        }
    }

    func udpFlowCount() -> Int {
        onQueue { udp.count }
    }

    func relayCount() -> Int {
        onQueue { relays.count }
    }

    private func configureTCP(_ connection: NWConnection, id: UInt32) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onQueue {
                if case .failed = state { self.closeTCP(id: id) }
                if case .cancelled = state, self.tcp[id] != nil { self.closeTCP(id: id) }
            }
        }
        receiveTCP(connection, id: id)
    }

    private func writeHostToCore(id: UInt32, data: Data) -> Int32 {
        guard let core else { return -1 }
        return data.withUnsafeBytes {
            macker_lwip_tcp_write(core, id, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
    }

    private func receiveTCP(_ connection: NWConnection, id: UInt32) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.onQueue {
                guard var flow = self.tcp[id] else { return }
                if let data, !data.isEmpty {
                    if flow.connected {
                        let result = self.writeHostToCore(id: id, data: data)
                        if result > 0 {
                            if flow.pendingToHost.count + data.count <= Self.maxPending {
                                flow.pendingToHost.append(data)
                            }
                            flow.receivePaused = true
                            self.tcp[id] = flow
                        } else if result < 0 {
                            self.closeTCP(id: id)
                            return
                        }
                    } else if flow.pendingToHost.count + data.count <= Self.maxPending {
                        flow.pendingToHost.append(data)
                        self.tcp[id] = flow
                    }
                }
                if complete || error != nil {
                    flow.hostFinished = true
                    self.tcp[id] = flow
                    if let core = self.core { _ = macker_lwip_tcp_fin(core, id) }
                    return
                }
                if self.tcp[id]?.receivePaused != true {
                    self.receiveTCP(connection, id: id)
                }
            }
        }
    }

    private func configureOutboundUDP(_ connection: NWConnection, id: UInt32) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.onQueue {
                if case .failed = state { self.closeUDP(id: id) }
                if case .cancelled = state, self.udp[id] != nil { self.closeUDP(id: id) }
            }
        }
        receiveUDP(connection, id: id)
    }

    private func receiveUDP(_ connection: NWConnection, id: UInt32) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.onQueue {
                guard self.udp[id] != nil else { return }
                self.touchUDP(id: id)
                if let data, let core = self.core {
                    _ = data.withUnsafeBytes {
                        macker_lwip_udp_write(core, id, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
                    }
                }
                if error == nil { self.receiveUDP(connection, id: id) }
                else { self.closeUDP(id: id) }
            }
        }
    }

    private func attachInbound(_ incoming: NWConnection, guestIP: GuestIPv4Address,
                               guestPort: UInt16, udp: Bool) {
        incoming.start(queue: queue)
        let id = allocateID()
        if udp {
            let flowPort = allocateRelayPort()
            guard flowPort != 0 else { incoming.cancel(); return }
            self.udp[id] = UDPFlow(id: id, key: Self.endpointKey(guestIP: guestIP, guestPort: guestPort,
                                                                remoteIP: NetworkGateway.gatewayAddress, remotePort: flowPort),
                                   guestIP: guestIP, guestPort: guestPort,
                                   flowPort: flowPort, connection: incoming, inbound: true)
            udpByEndpoint[Self.endpointKey(guestIP: guestIP, guestPort: guestPort,
                                           remoteIP: NetworkGateway.gatewayAddress, remotePort: flowPort)] = id
            guard let core, macker_lwip_udp_inbound_start(core, id, Self.address(guestIP), guestPort, flowPort) == 0 else {
                closeUDP(id: id); return
            }
            configureOutboundUDP(incoming, id: id)
        } else {
            let flowPort = allocateRelayPort()
            guard flowPort != 0 else { incoming.cancel(); return }
            self.tcp[id] = TCPFlow(id: id, key: Self.endpointKey(guestIP: guestIP, guestPort: guestPort,
                                                                remoteIP: NetworkGateway.gatewayAddress, remotePort: flowPort),
                                   guestIP: guestIP, guestPort: guestPort,
                                   remoteIP: NetworkGateway.gatewayAddress, remotePort: flowPort,
                                   connection: incoming, inbound: true)
            tcpByEndpoint[Self.endpointKey(guestIP: guestIP, guestPort: guestPort,
                                           remoteIP: NetworkGateway.gatewayAddress, remotePort: flowPort)] = id
            guard let core, macker_lwip_tcp_inbound_start(core, id, Self.address(guestIP), guestPort, flowPort) == 0 else {
                closeTCP(id: id); return
            }
            configureTCP(incoming, id: id)
        }
    }

    private func receivedOutput(id: UInt32, packet: Data) {
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            if let flow = self.tcp[id] { self.onGuest(flow.guestIP, packet) }
            else if let flow = self.udp[id] { self.onGuest(flow.guestIP, packet) }
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            deliver()
        } else {
            queue.async(execute: deliver)
        }
    }

    private func receivedEvent(id: UInt32, event: Int32, data: Data) {
        // Callbacks run while the core lock may be held. Never wait on the Swift queue here.
        queue.async { [weak self] in
            guard let self else { return }
            switch event {
            case Int32(MACKER_LWIP_EVENT_DATA):
                if var flow = self.tcp[id] {
                    if flow.connection != nil {
                        flow.connection?.send(content: data, completion: .idempotent)
                    } else if flow.pendingToHost.count + data.count <= Self.maxPending {
                        flow.pendingToHost.append(data)
                        self.tcp[id] = flow
                    }
                } else if let flow = self.udp[id] {
                    self.touchUDP(id: id)
                    flow.connection?.send(content: data, completion: .idempotent)
                }
            case Int32(MACKER_LWIP_EVENT_CONNECTED):
                if var flow = self.tcp[id] {
                    flow.connected = true
                    self.tcp[id] = flow
                }
                self.flushTCP(id: id)
            case Int32(MACKER_LWIP_EVENT_WRITABLE):
                self.flushTCP(id: id)
                if var flow = self.tcp[id], flow.receivePaused, let connection = flow.connection {
                    flow.receivePaused = false
                    self.tcp[id] = flow
                    self.receiveTCP(connection, id: id)
                }
            case Int32(MACKER_LWIP_EVENT_CLOSED), Int32(MACKER_LWIP_EVENT_ERROR):
                if self.tcp[id] != nil { self.closeTCP(id: id, closeCore: false) }
                else if self.udp[id] != nil { self.closeUDP(id: id, closeCore: false) }
            default:
                break
            }
        }
    }

    private func flushTCP(id: UInt32) {
        guard var flow = tcp[id], !flow.pendingToHost.isEmpty else { return }
        guard let core else { return }
        let pending = flow.pendingToHost
        flow.pendingToHost.removeAll(keepingCapacity: true)
        tcp[id] = flow
        let result = pending.withUnsafeBytes {
            macker_lwip_tcp_write(core, id, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        if result != 0, var flow = tcp[id] {
            if result > 0 {
                flow.pendingToHost = pending + flow.pendingToHost
                flow.receivePaused = true
                tcp[id] = flow
            }
        }
    }

    private func sendTCPToCore(id: UInt32, packet: Data) {
        enqueueTCPInput(id: id, packet: packet)
        flushTCPInput()
    }

    private func enqueueTCPInput(id: UInt32, packet: Data) {
        tcpInputBatch.append((id, packet))
    }

    private func flushTCPInput() {
        guard let core, !tcpInputBatch.isEmpty else { return }
        let batch = tcpInputBatch
        tcpInputBatch.removeAll(keepingCapacity: true)

        let ids = batch.map(\.id)
        let lengths = batch.map(\.packet.count)
        var storage = [UInt8]()
        storage.reserveCapacity(lengths.reduce(0, +))
        var offsets = [Int]()
        offsets.reserveCapacity(batch.count)
        for item in batch {
            offsets.append(storage.count)
            storage.append(contentsOf: item.packet)
        }

        ids.withUnsafeBufferPointer { idBuffer in
            lengths.withUnsafeBufferPointer { lengthBuffer in
                storage.withUnsafeBufferPointer { bytes in
                    guard let base = bytes.baseAddress else { return }
                    let pointers: [UnsafePointer<UInt8>?] = offsets.map { base + $0 }
                    pointers.withUnsafeBufferPointer { pointerBuffer in
                        _ = macker_lwip_tcp_input_many(
                            core,
                            idBuffer.baseAddress,
                            pointerBuffer.baseAddress,
                            lengthBuffer.baseAddress,
                            batch.count
                        )
                    }
                }
            }
        }
    }

    private func sendUDPToCore(id: UInt32, packet: Data, first: Bool = false,
                               remoteIP: GuestIPv4Address? = nil, remotePort: UInt16 = 0) {
        guard let core else { return }
        if first, let remoteIP {
            let flow = udp[id]
            let guestIP = flow?.guestIP ?? .init(0)
            let guestPort = flow?.guestPort ?? 0
            let result = packet.withUnsafeBytes { bytes in
                macker_lwip_udp_outbound_start(core, id, Self.address(remoteIP), remotePort,
                                               Self.address(guestIP), guestPort,
                                               bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            if result != 0 { closeUDP(id: id) }
        } else {
            _ = packet.withUnsafeBytes {
                macker_lwip_udp_input(core, id, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
        }
    }

    private func closeTCP(id: UInt32, closeCore: Bool = true) {
        guard let flow = tcp.removeValue(forKey: id) else { return }
        tcpByEndpoint.removeValue(forKey: flow.key)
        flow.connection?.cancel()
        if closeCore, let core { macker_lwip_tcp_close(core, id) }
    }

    private func closeUDP(id: UInt32, closeCore: Bool = true) {
        guard let flow = udp.removeValue(forKey: id) else { return }
        udpByEndpoint.removeValue(forKey: flow.key)
        flow.connection?.cancel()
        if closeCore, let core { macker_lwip_udp_close(core, id) }
    }

    private func allocateID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    private func allocateRelayPort() -> UInt16 {
        for _ in 0..<10_000 {
            let candidate = nextRelayPort
            nextRelayPort = candidate == 59_999 ? 50_000 : candidate &+ 1
            let tcpUsed = tcp.values.contains { $0.inbound && $0.remotePort == candidate }
            let udpUsed = udp.values.contains { $0.inbound && $0.flowPort == candidate }
            if !tcpUsed && !udpUsed { return candidate }
        }
        return 0
    }

    private func touchUDP(id: UInt32) {
        guard var flow = udp[id] else { return }
        flow.lastActivity = Date()
        udp[id] = flow
    }

    private func sweepIdleUDP() {
        let cutoff = Date().addingTimeInterval(-udpIdleTimeout)
        let expired = udp.values.filter { !$0.inbound && $0.lastActivity < cutoff }.map(\.id)
        for id in expired {
            closeUDP(id: id)
        }
    }

    private func enqueue(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { body() }
        else { queue.async(execute: body) }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { body() }
        else { queue.sync(execute: body) }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    private static func endpointKey(guestIP: GuestIPv4Address, guestPort: UInt16,
                                   remoteIP: GuestIPv4Address, remotePort: UInt16) -> FlowKey {
        FlowKey(guestIP: address(guestIP), remoteIP: address(remoteIP),
                guestPort: guestPort, remotePort: remotePort)
    }

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private static func address(_ ip: GuestIPv4Address) -> UInt32 {
        ip.bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static let outputCallback: macker_lwip_output_fn = { context, id, packet, length in
        guard let context, let packet else { return }
        let owner = Unmanaged<GatewayLwIP>.fromOpaque(context).takeUnretainedValue()
        owner.receivedOutput(id: id, packet: Data(bytes: packet, count: length))
    }

    private static let eventCallback: macker_lwip_event_fn = { context, id, event, data, length in
        guard let context else { return }
        let owner = Unmanaged<GatewayLwIP>.fromOpaque(context).takeUnretainedValue()
        if event == Int32(MACKER_LWIP_EVENT_DATA), let data, length > 0 {
            owner.receivedEvent(id: id, event: event, data: Data(bytes: data, count: length))
        } else {
            owner.receivedEvent(id: id, event: event, data: Data())
        }
    }
}
