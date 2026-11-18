import ContainerizationExtras
import Foundation
import Network
import os
import SwiftTCP

typealias GuestIPv4Address = ContainerizationExtras.IPv4Address
typealias GuestIPv6Address = ContainerizationExtras.IPv6Address

/// Userspace gateway forwarder backed by the SwiftTCP library.
///
/// Guest TCP/UDP is terminated in-process; application payloads ride Mac `NWConnection`s.
/// Same-network L3, ARP, ICMP echo and embedded DNS stay in ``BridgeDataplane``.
final class GatewaySwiftTCP: GatewayForwarder, @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<UInt8>()

    private struct LocalRelay {
        let listener: NWListener
        let guestIP: GuestIPv4Address
        let guestPort: UInt16
        let gatewayIP: GuestIPv4Address
        let udp: Bool
    }

    private struct UDPInbound {
        let connection: NWConnection
        let guestIP: GuestIPv4Address
        let guestPort: UInt16
    }

    private enum IngestWork: Sendable {
        case batch([Data])
        case closed
    }

    private struct IngestState {
        var pending: [Data] = []
        var waiter: CheckedContinuation<IngestWork, Never>?
        var closed = false
        var pumping = false
    }

    private let onGuest: @Sendable (GuestIPv4Address, Data) -> Void
    private let onGuest6: @Sendable (GuestIPv6Address, Data) -> Void
    private let sink: GuestSink
    private let host: HostTCPBridge
    private let stack: SwiftStack
    private let icmp: GatewayICMP
    private let queue = DispatchQueue(label: "io.macker.net.swifttcp")
    private let ingest = OSAllocatedUnfairLock(initialState: IngestState())
    private let lock = OSAllocatedUnfairLock(initialState: ControlState())
    private let gateways = OSAllocatedUnfairLock(initialState: Set<UInt32>())
    private let gateways6 = OSAllocatedUnfairLock(initialState: Set<IPv6Key>())

    private struct ControlState {
        var relays: [LocalRelay] = []
        var inboundTCP: [FlowKey: (guestIP: GuestIPv4Address, guestPort: UInt16)] = [:]
        var inboundUDP: [FlowKey: UDPInbound] = [:]
        var usedRelayPorts: Set<UInt16> = []
        var nextRelayPort: UInt16 = 50_000

        mutating func allocateRelayPort() -> UInt16 {
            for _ in 0..<10_000 {
                let candidate = nextRelayPort
                nextRelayPort = candidate == 59_999 ? 50_000 : candidate &+ 1
                if usedRelayPorts.insert(candidate).inserted {
                    return candidate
                }
            }
            return 0
        }
    }

    init(
        onGuest: @escaping @Sendable (GuestIPv4Address, Data) -> Void,
        onGuest6: @escaping @Sendable (GuestIPv6Address, Data) -> Void = { _, _ in },
        udpIdleTimeout: TimeInterval = 60
    ) {
        self.onGuest = onGuest
        self.onGuest6 = onGuest6
        queue.setSpecific(key: Self.queueKey, value: 1)
        let sink = GuestSink(onGuest: onGuest, onGuest6: onGuest6)
        let host = HostTCPBridge()
        let idle = Duration.milliseconds(Int64((udpIdleTimeout * 1000).rounded(.up)))
        let stack = SwiftStack(
            config: SwiftStackConfig(
                tcp: TCPStackConfig(
                    receiveWindow: 1024 * 1024,
                    tfo: false,
                    maxMss: UInt16(clamping: FileHandleLink.virtioMTU - 60)
                ),
                mtu: FileHandleLink.virtioMTU,
                udpIdle: idle
            ),
            sink: sink,
            streams: host
        )
        host.stream = stack
        self.sink = sink
        self.host = host
        self.stack = stack
        self.icmp = GatewayICMP(onGuest: onGuest, onGuest6: onGuest6)
    }

    func handleICMP(_ packet: Data) {
        icmp.ingest(packet)
    }

    func handleICMPv6(_ packet: Data) {
        icmp.ingest6(packet)
    }

    deinit {
        closeAll()
    }

    func setGateways(_ ips: Set<UInt32>) {
        gateways.withLock { $0 = ips }
    }

    func setGateways6(_ ips: Set<IPv6Key>) {
        gateways6.withLock { $0 = ips }
    }

    func ingestIPv4(_ packet: Data) {
        if let header = IPv4Peek.tuple(packet),
            header.proto == Ethernet.protoTCP,
            header.tcpFlags & ContainerEngine.TCPSegment.Flags.syn.rawValue != 0,
            header.tcpFlags & ContainerEngine.TCPSegment.Flags.ack.rawValue == 0,
            !gateways.withLock({ $0.contains(header.dst) })
        {
            host.preconnect(Self.flow(header))
        }
        enqueueIngest(packet)
    }

    func ingestIPv6(_ packet: Data) {
        if let header = IPv6Peek.tuple(packet),
            header.nextHeader == Ethernet.protoTCP,
            header.tcpFlags & ContainerEngine.TCPSegment.Flags.syn.rawValue != 0,
            header.tcpFlags & ContainerEngine.TCPSegment.Flags.ack.rawValue == 0,
            !gateways6.withLock({ $0.contains(header.dst) })
        {
            host.preconnect(Self.flow6(header))
        }
        enqueueIngest(packet)
    }

    func acceptIPv4(_ packet: Data) -> Bool {
        guard let header = IPv4Peek.tuple(packet) else { return false }
        let flow = Self.flow(header)
        let owned = lock.withLock {
            $0.inboundTCP[flow] != nil || $0.inboundUDP[flow] != nil
        }
        guard owned else { return false }
        if header.proto == Ethernet.protoUDP {
            deliverInboundUDP(flow: flow, packet: packet)
            return true
        }
        enqueueIngest(packet)
        return true
    }

    func forwardDNS(
        query: Data,
        guestIP: GuestIPv4Address,
        guestPort: UInt16,
        gatewayIP: GuestIPv4Address,
        upstreams: [String]
    ) {
        let server = upstreams.first ?? GatewayDNS.primaryUpstream
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(server), port: 53)
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: query, completion: .contentProcessed { error in
                    if error != nil { connection.cancel() }
                })
            }
            if case .failed = state { connection.cancel() }
        }
        queue.asyncAfter(deadline: .now() + .seconds(5)) {
            connection.cancel()
        }
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            let datagram = UDPDatagram(srcPort: 53, dstPort: guestPort, payload: data)
            let payload = datagram.encode(src: gatewayIP, dst: guestIP)
            let packet = IPv4Packet(
                tos: 0, id: 0, ttl: 64, proto: Ethernet.protoUDP,
                src: gatewayIP, dst: guestIP, payload: payload
            )
            self.onGuest(guestIP, packet.encode())
            connection.cancel()
        }
        connection.start(queue: queue)
    }

    func forwardDNS6(
        query: Data,
        guestIP: GuestIPv6Address,
        guestPort: UInt16,
        gatewayIP: GuestIPv6Address,
        upstreams: [String]
    ) {
        let server = upstreams.first ?? GatewayDNS.primaryUpstream
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(server), port: 53)
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: query, completion: .contentProcessed { error in
                    if error != nil { connection.cancel() }
                })
            }
            if case .failed = state { connection.cancel() }
        }
        queue.asyncAfter(deadline: .now() + .seconds(5)) {
            connection.cancel()
        }
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            let datagram = UDPDatagram(srcPort: 53, dstPort: guestPort, payload: data)
            let payload = datagram.encode(src: gatewayIP, dst: guestIP)
            let packet = IPv6Packet(
                hopLimit: 64,
                nextHeader: Ethernet.protoUDP,
                src: gatewayIP,
                dst: guestIP,
                payload: payload
            )
            self.onGuest6(guestIP, packet.encode())
            connection.cancel()
        }
        connection.start(queue: queue)
    }
}

extension GatewaySwiftTCP {
    func listenLocal(
        guestIP: GuestIPv4Address,
        guestPort: UInt16,
        udp: Bool,
        gatewayIP: GuestIPv4Address = NetworkGateway.defaultGatewayIP
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    let parameters = udp ? NWParameters.udp : Self.tcpParameters()
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters, on: .any)
                    listener.newConnectionHandler = { [weak self] incoming in
                        guard let self else { return }
                        self.enqueue {
                            self.attachInbound(
                                incoming,
                                guestIP: guestIP,
                                guestPort: guestPort,
                                gatewayIP: gatewayIP,
                                udp: udp
                            )
                        }
                    }
                    let pending = OSAllocatedUnfairLock<CheckedContinuation<Int, Error>?>(initialState: continuation)
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            self?.enqueue { [weak self] in
                                self?.lock.withLock {
                                    $0.relays.append(
                                        LocalRelay(
                                            listener: listener,
                                            guestIP: guestIP,
                                            guestPort: guestPort,
                                            gatewayIP: gatewayIP,
                                            udp: udp
                                        )
                                    )
                                }
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

    func stopListenLocal(guestIP: GuestIPv4Address, guestPort: UInt16, udp: Bool) {
        onQueue {
            let removed = self.lock.withLock { state -> [LocalRelay] in
                let removed = state.relays.filter {
                    $0.guestIP == guestIP && $0.guestPort == guestPort && $0.udp == udp
                }
                state.relays.removeAll {
                    $0.guestIP == guestIP && $0.guestPort == guestPort && $0.udp == udp
                }
                return removed
            }
            removed.forEach { $0.listener.cancel() }
            if udp {
                self.lock.withLock { state in
                    let keys = state.inboundUDP.filter {
                        $0.value.guestIP == guestIP && $0.value.guestPort == guestPort
                    }.map(\.key)
                    for key in keys {
                        if let session = state.inboundUDP.removeValue(forKey: key) {
                            session.connection.cancel()
                            state.usedRelayPorts.remove(key.dstPort)
                        }
                    }
                }
            } else {
                let flows = self.lock.withLock { state -> [FlowKey] in
                    let keys = state.inboundTCP.filter {
                        $0.value.guestIP == guestIP && $0.value.guestPort == guestPort
                    }.map(\.key)
                    for key in keys {
                        state.inboundTCP.removeValue(forKey: key)
                        state.usedRelayPorts.remove(key.dstPort)
                    }
                    return keys
                }
                for flow in flows {
                    self.host.cancel(flow)
                    Task { await self.stack.close(flow: flow) }
                }
            }
        }
    }

    func closeAll() {
        let already = ingest.withLock { state -> Bool in
            if state.closed { return true }
            state.closed = true
            state.pending.removeAll()
            if let waiter = state.waiter {
                state.waiter = nil
                waiter.resume(returning: .closed)
            }
            return false
        }
        guard !already else { return }
        icmp.close()
        let done = DispatchSemaphore(value: 0)
        enqueue {
            let snapshot = self.lock.withLock { state -> ControlState in
                let copy = state
                state.relays.removeAll()
                state.inboundTCP.removeAll()
                state.inboundUDP.removeAll()
                state.usedRelayPorts.removeAll()
                return copy
            }
            snapshot.relays.forEach { $0.listener.cancel() }
            snapshot.inboundUDP.values.forEach { $0.connection.cancel() }
            self.host.closeAll()
            let stack = self.stack
            Task {
                await stack.shutdown()
                done.signal()
            }
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil {
            _ = done.wait(timeout: .now() + 2)
        }
    }

    func relayCount() -> Int {
        lock.withLock { $0.relays.count }
    }

    private func attachInbound(
        _ incoming: NWConnection,
        guestIP: GuestIPv4Address,
        guestPort: UInt16,
        gatewayIP: GuestIPv4Address,
        udp: Bool
    ) {
        incoming.start(queue: queue)
        let flowPort = lock.withLock { $0.allocateRelayPort() }
        guard flowPort != 0 else {
            incoming.cancel()
            return
        }
        let flow = FlowKey(
            src: IPAddress(v4: guestIP.value),
            srcPort: guestPort,
            dst: IPAddress(v4: gatewayIP.value),
            dstPort: flowPort
        )
        if udp {
            lock.withLock {
                $0.inboundUDP[flow] = UDPInbound(
                    connection: incoming,
                    guestIP: guestIP,
                    guestPort: guestPort
                )
            }
            receiveInboundUDP(flow: flow, connection: incoming)
        } else {
            lock.withLock {
                $0.inboundTCP[flow] = (guestIP, guestPort)
            }
            host.attachInbound(flow: flow, connection: incoming)
            Task { await stack.connect(flow: flow) }
        }
    }

    private func receiveInboundUDP(flow: FlowKey, connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let guestIP = self.lock.withLock { $0.inboundUDP[flow]?.guestIP }
                if let guestIP {
                    let packet = UDPPacket.encapsulate(flow: flow.reversed, payload: data)
                    self.onGuest(guestIP, packet.asSharedData())
                }
            }
            if complete || error != nil {
                self.lock.withLock { state in
                    state.inboundUDP.removeValue(forKey: flow)?.connection.cancel()
                    state.usedRelayPorts.remove(flow.dstPort)
                }
                return
            }
            self.receiveInboundUDP(flow: flow, connection: connection)
        }
    }

    private func deliverInboundUDP(flow: FlowKey, packet: Data) {
        guard let parsed = IPv4Packet.parse(packet),
            let datagram = UDPDatagram.parse(parsed.payload)
        else { return }
        let connection = lock.withLock { $0.inboundUDP[flow]?.connection }
        connection?.send(content: datagram.payload, completion: .contentProcessed { _ in })
    }

    private func enqueueIngest(_ packet: Data) {
        let startPump = ingest.withLock { state -> Bool in
            if state.closed { return false }
            state.pending.append(packet)
            if let waiter = state.waiter {
                state.waiter = nil
                let batch = state.pending
                state.pending.removeAll(keepingCapacity: true)
                waiter.resume(returning: .batch(batch))
            }
            if state.pumping { return false }
            state.pumping = true
            return true
        }
        if startPump {
            Task { await self.runIngestPump() }
        }
    }

    private func runIngestPump() async {
        while true {
            switch await takeIngestWork() {
            case .closed:
                ingest.withLock { $0.pumping = false }
                return
            case .batch(let batch):
                await stack.ingestBatch(batch)
            }
        }
    }

    private func takeIngestWork() async -> IngestWork {
        await withCheckedContinuation { continuation in
            ingest.withLock { state in
                if state.closed, state.pending.isEmpty {
                    continuation.resume(returning: .closed)
                    return
                }
                if !state.pending.isEmpty {
                    let batch = state.pending
                    state.pending.removeAll(keepingCapacity: true)
                    continuation.resume(returning: .batch(batch))
                    return
                }
                state.waiter = continuation
            }
        }
    }

    private func enqueue(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            body()
        } else {
            queue.async(execute: body)
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private static func flow(_ header: IPv4Peek.Tuple) -> FlowKey {
        FlowKey(
            src: IPAddress(v4: header.src),
            srcPort: header.srcPort,
            dst: IPAddress(v4: header.dst),
            dstPort: header.dstPort
        )
    }

    private static func flow6(_ header: IPv6Peek.Tuple) -> FlowKey {
        FlowKey(
            src: IPAddress(v6High: header.src.high, v6Low: header.src.low),
            srcPort: header.srcPort,
            dst: IPAddress(v6High: header.dst.high, v6Low: header.dst.low),
            dstPort: header.dstPort
        )
    }

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = false
        return NWParameters(tls: nil, tcp: tcp)
    }
}

private final class GuestSink: PacketSink, @unchecked Sendable {
    let onGuest: @Sendable (GuestIPv4Address, Data) -> Void
    let onGuest6: @Sendable (GuestIPv6Address, Data) -> Void

    init(
        onGuest: @escaping @Sendable (GuestIPv4Address, Data) -> Void,
        onGuest6: @escaping @Sendable (GuestIPv6Address, Data) -> Void
    ) {
        self.onGuest = onGuest
        self.onGuest6 = onGuest6
    }

    func write(bytes: Data, protocolFamily: UInt8) {
        _ = protocolFamily
        guard let first = bytes.first else { return }
        switch first >> 4 {
        case 4:
            guard bytes.count >= 20 else { return }
            onGuest(GuestIPv4Address(IPv4Peek.read32(bytes, 16)), bytes)
        case 6:
            guard bytes.count >= 40 else { return }
            let dst = bytes.withUnsafeBytes { raw in
                IPv6Key(high: IPv6Peek.read64(raw, 24), low: IPv6Peek.read64(raw, 32)).address
            }
            onGuest6(dst, bytes)
        default:
            break
        }
    }
}

/// Mac-side byte pump. Not an actor: `TCPStreamHandler` callbacks run on the TCP EventLoop.
private final class HostTCPBridge: TCPStreamHandler, @unchecked Sendable {
    /// Bound for in-flight proxy buffers. Must exceed the SwiftTCP receive window so a full
    /// window cannot RST a healthy bulk transfer. Overflow resets the flow instead of dropping bytes.
    private static let maxPending = 4 * 1024 * 1024
    private static let receiveChunk = 1024 * 1024

    private struct State {
        var connections: [FlowKey: NWConnection] = [:]
        var inbound: Set<FlowKey> = []
        var established: Set<FlowKey> = []
        var pendingToGuest: [FlowKey: Data] = [:]
        var pendingToHost: [FlowKey: Data] = [:]
        var receivePaused: Set<FlowKey> = []
        var hostSending: Set<FlowKey> = []
    }

    var stream: (any TCPByteStream)?
    private let queue = DispatchQueue(label: "io.macker.net.swifttcp.host")
    private let lock = OSAllocatedUnfairLock(initialState: State())

    func preconnect(_ flow: FlowKey) {
        queue.async { self.openOutbound(flow) }
    }

    func attachInbound(flow: FlowKey, connection: NWConnection) {
        lock.withLock { state in
            state.inbound.insert(flow)
            state.connections[flow] = connection
        }
        receive(flow, connection)
    }

    func cancel(_ flow: FlowKey) {
        let connection = lock.withLock { state -> NWConnection? in
            state.inbound.remove(flow)
            state.established.remove(flow)
            state.pendingToGuest.removeValue(forKey: flow)
            state.pendingToHost.removeValue(forKey: flow)
            state.receivePaused.remove(flow)
            state.hostSending.remove(flow)
            return state.connections.removeValue(forKey: flow)
        }
        connection?.cancel()
    }

    func closeAll() {
        let connections = lock.withLock { state -> [NWConnection] in
            let values = Array(state.connections.values)
            state = State()
            return values
        }
        connections.forEach { $0.cancel() }
    }

    func onEstablished(flow: FlowKey) {
        queue.async { self.handleEstablished(flow) }
    }

    func onData(flow: FlowKey, data: Data) {
        enum Action {
            case none
            case pump(NWConnection, Data)
            case overflow
        }
        let action = lock.withLock { state -> Action in
            let queued = state.pendingToHost[flow]?.count ?? 0
            if queued + data.count > Self.maxPending {
                return .overflow
            }
            state.pendingToHost[flow, default: Data()].append(data)
            guard let connection = state.connections[flow], !state.hostSending.contains(flow) else {
                return .none
            }
            let pending = state.pendingToHost.removeValue(forKey: flow) ?? Data()
            guard !pending.isEmpty else { return .none }
            state.hostSending.insert(flow)
            return .pump(connection, pending)
        }
        switch action {
        case .none:
            break
        case .pump(let connection, let pending):
            pumpHost(flow, connection, pending)
        case .overflow:
            fail(flow)
        }
    }

    func onClosed(flow: FlowKey) {
        queue.async { self.cancel(flow) }
    }

    private func handleEstablished(_ flow: FlowKey) {
        let inbound = lock.withLock { $0.inbound.contains(flow) }
        if !inbound {
            openOutbound(flow)
        }
        let pendingGuest = lock.withLock { state -> Data in
            state.established.insert(flow)
            return state.pendingToGuest.removeValue(forKey: flow) ?? Data()
        }
        let pendingHost = lock.withLock { state -> (NWConnection, Data)? in
            guard let connection = state.connections[flow], !state.hostSending.contains(flow) else {
                return nil
            }
            let pending = state.pendingToHost.removeValue(forKey: flow) ?? Data()
            guard !pending.isEmpty else { return nil }
            state.hostSending.insert(flow)
            return (connection, pending)
        }
        if let pendingHost {
            pumpHost(flow, pendingHost.0, pendingHost.1)
        }
        if !pendingGuest.isEmpty, let stream {
            stream.sendDetached(flow: flow, data: pendingGuest) { [weak self] _ in
                self?.resumeReceive(flow)
            }
        } else {
            resumeReceive(flow)
        }
    }

    private func openOutbound(_ flow: FlowKey) {
        let exists = lock.withLock { state -> Bool in
            if state.inbound.contains(flow) { return true }
            return state.connections[flow] != nil
        }
        if exists { return }
        guard let port = NWEndpoint.Port(rawValue: flow.dstPort) else { return }
        let connection = NWConnection(
            to: NWEndpoint.hostPort(host: NWEndpoint.Host(flow.dst.description), port: port),
            using: tcpParameters()
        )
        lock.withLock { $0.connections[flow] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.fail(flow)
            }
            if case .cancelled = state {
                self.fail(flow)
            }
        }
        connection.start(queue: queue)
        receive(flow, connection)
    }

    private func receive(_ flow: FlowKey, _ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let established = self.lock.withLock { $0.established.contains(flow) }
                if established, let stream = self.stream {
                    stream.sendDetached(flow: flow, data: data) { [weak self] accepted in
                        guard let self else { return }
                        if accepted < data.count || complete || error != nil {
                            self.finishHost(flow, connection: connection)
                        } else {
                            self.receive(flow, connection)
                        }
                    }
                    return
                }
                let overflow = self.lock.withLock { state -> Bool in
                    let queued = state.pendingToGuest[flow]?.count ?? 0
                    if queued + data.count > Self.maxPending {
                        state.receivePaused.insert(flow)
                        return true
                    }
                    state.pendingToGuest[flow, default: Data()].append(data)
                    state.receivePaused.insert(flow)
                    return false
                }
                if overflow {
                    self.fail(flow)
                    return
                }
            }
            if complete || error != nil {
                self.finishHost(flow, connection: connection)
                return
            }
            let paused = self.lock.withLock { $0.receivePaused.contains(flow) }
            if !paused {
                self.receive(flow, connection)
            }
        }
    }

    private func resumeReceive(_ flow: FlowKey) {
        let connection = lock.withLock { state -> NWConnection? in
            guard state.receivePaused.remove(flow) != nil else { return nil }
            return state.connections[flow]
        }
        if let connection {
            receive(flow, connection)
        }
    }

    private func finishHost(_ flow: FlowKey, connection: NWConnection) {
        connection.cancel()
        if let stream {
            Task { await stream.close(flow: flow) }
        }
    }

    private func fail(_ flow: FlowKey) {
        cancel(flow)
        if let stream {
            Task { await stream.close(flow: flow) }
        }
    }

    private func pumpHost(_ flow: FlowKey, _ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.fail(flow)
                return
            }
            let next = self.lock.withLock { state -> (NWConnection, Data)? in
                let pending = state.pendingToHost.removeValue(forKey: flow) ?? Data()
                if pending.isEmpty {
                    state.hostSending.remove(flow)
                    return nil
                }
                return (state.connections[flow] ?? connection, pending)
            }
            if let next {
                self.pumpHost(flow, next.0, next.1)
            }
        })
    }

    private func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = false
        return NWParameters(tls: nil, tcp: tcp)
    }
}
