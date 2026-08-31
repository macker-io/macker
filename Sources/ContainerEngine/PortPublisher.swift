import Foundation
import Network
import os

/// Userspace TCP/UDP proxy: Mac listen port → `containerIP:containerPort`.
final class PortPublisher: @unchecked Sendable {
    private struct Live {
        var listener: NWListener
        var connections: [ObjectIdentifier: NWConnection] = [:]
    }

    private enum Transport: String {
        case tcp
        case udp

        init(_ name: String) throws {
            guard let value = Transport(rawValue: name.lowercased()) else {
                throw EngineError.invalidArgument("unsupported publish protocol \(name)")
            }
            self = value
        }

        var parameters: NWParameters {
            let parameters: NWParameters
            if self == .udp {
                parameters = .udp
            } else {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                parameters = NWParameters(tls: nil, tcp: tcp)
            }
            parameters.allowLocalEndpointReuse = true
            return parameters
        }
    }

    private let queue = DispatchQueue(label: "io.macker.ports")
    private let lock = OSAllocatedUnfairLock(initialState: [String: Live]())

    func publish(
        key: String,
        hostIP: String,
        hostPort: Int,
        containerIP: String,
        containerPort: Int,
        protocolName: String,
        localIP: String = ""
    ) async throws -> Int {
        guard (0...65535).contains(hostPort), (1...65535).contains(containerPort) else {
            throw EngineError.invalidArgument("invalid port mapping \(hostPort):\(containerPort)")
        }
        guard !containerIP.isEmpty else {
            throw EngineError.invalidArgument("cannot publish ports before the container has an IP")
        }
        let transport = try Transport(protocolName)

        let listener: NWListener
        do {
            listener = try Self.makeListener(
                parameters: transport.parameters,
                hostIP: hostIP,
                hostPort: hostPort
            )
        } catch {
            throw EngineError.conflict("failed to bind \(Self.displayHost(hostIP)):\(hostPort)/\(transport.rawValue): \(error.localizedDescription)")
        }

        let pending = OSAllocatedUnfairLock<CheckedContinuation<Int, Error>?>(initialState: nil)
        lock.withLock { state in
            state[key] = Live(listener: listener)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = listener.port.map { Int($0.rawValue) } ?? hostPort
                pending.withLock { continuation in
                    continuation?.resume(returning: port)
                    continuation = nil
                }
            case .failed(let error):
                pending.withLock { continuation in
                    continuation?.resume(
                        throwing: EngineError.conflict(
                            "failed to listen on \(Self.displayHost(hostIP)):\(hostPort)/\(transport.rawValue): \(error.localizedDescription)"
                        )
                    )
                    continuation = nil
                }
            case .cancelled:
                pending.withLock { continuation in
                    continuation?.resume(throwing: EngineError.conflict("port publisher cancelled"))
                    continuation = nil
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] incoming in
            self?.bridge(
                incoming,
                key: key,
                to: containerIP,
                port: containerPort,
                transport: transport,
                localIP: localIP
            )
        }

        do {
            let bound = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                pending.withLock { $0 = continuation }
                listener.start(queue: self.queue)
            }
            return bound
        } catch {
            unpublish(keysMatching: key)
            throw error
        }
    }

    func unpublish(keysMatching prefix: String) {
        let removed: [Live] = lock.withLock { state in
            let keys = state.keys.filter { $0.hasPrefix(prefix) }
            return keys.compactMap { state.removeValue(forKey: $0) }
        }
        for live in removed {
            cancel(live)
        }
    }

    private func bridge(
        _ incoming: NWConnection,
        key: String,
        to containerIP: String,
        port: Int,
        transport: Transport,
        localIP: String
    ) {
        guard let targetPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            incoming.cancel()
            return
        }
        let parameters = transport.parameters
        if !localIP.isEmpty {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(localIP),
                port: 0
            )
        }
        let outgoing = NWConnection(
            host: NWEndpoint.Host(containerIP),
            port: targetPort,
            using: parameters
        )
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
        remember(incoming, key: key)
        remember(outgoing, key: key)
        switch transport {
        case .tcp:
            pipeStream(incoming, to: outgoing)
            pipeStream(outgoing, to: incoming)
        case .udp:
            pipeDatagrams(incoming, to: outgoing)
            pipeDatagrams(outgoing, to: incoming)
        }
    }

    private func cancel(_ live: Live) {
        live.listener.cancel()
        for connection in live.connections.values {
            connection.cancel()
        }
    }

    private func closePair(_ from: NWConnection, _ to: NWConnection) {
        from.cancel()
        to.cancel()
    }

    private func pipeStream(_ from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let publisher = self else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete || error != nil {
                        to.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                            publisher.closePair(from, to)
                        })
                        return
                    }
                    publisher.pipeStream(from, to: to)
                })
                return
            }
            if isComplete || error != nil {
                to.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    publisher.closePair(from, to)
                })
                return
            }
            publisher.pipeStream(from, to: to)
        }
    }

    /// `isComplete` marks the end of one datagram, not the end of the flow, so the only reason
    /// to tear a UDP pair down is an error. Idle pairs go away when the container is unpublished.
    private func pipeDatagrams(_ from: NWConnection, to: NWConnection) {
        from.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                self.closePair(from, to)
                return
            }
            guard let data, !data.isEmpty else {
                self.pipeDatagrams(from, to: to)
                return
            }
            to.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { sendError in
                if sendError != nil {
                    self.closePair(from, to)
                    return
                }
                self.pipeDatagrams(from, to: to)
            })
        }
    }

    private func remember(_ connection: NWConnection, key: String) {
        let id = ObjectIdentifier(connection)
        lock.withLock { state in
            state[key]?.connections[id] = connection
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.forget(id, key: key)
            }
            if case .failed = state {
                connection.cancel()
                self?.forget(id, key: key)
            }
        }
    }

    private func forget(_ id: ObjectIdentifier, key: String) {
        lock.withLock { state in
            state[key]?.connections[id] = nil
        }
    }

    private static func makeListener(parameters: NWParameters, hostIP: String, hostPort: Int) throws -> NWListener {
        let port: NWEndpoint.Port
        if hostPort == 0 {
            port = .any
        } else if let value = NWEndpoint.Port(rawValue: UInt16(hostPort)) {
            port = value
        } else {
            throw EngineError.invalidArgument("invalid host port \(hostPort)")
        }

        if !hostIP.isEmpty, hostIP != "0.0.0.0", hostIP != "::" {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hostIP), port: port)
            return try NWListener(using: parameters)
        }
        return try NWListener(using: parameters, on: port)
    }

    private static func displayHost(_ hostIP: String) -> String {
        hostIP.isEmpty ? "0.0.0.0" : hostIP
    }
}
