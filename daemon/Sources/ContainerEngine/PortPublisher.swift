import Foundation
import Network
import os

/// Userspace TCP proxy: Mac listen port → `containerIP:containerPort`.
final class PortPublisher: @unchecked Sendable {
    private struct Live {
        var listener: NWListener
        var connections: [ObjectIdentifier: NWConnection] = [:]
    }

    private let queue = DispatchQueue(label: "io.macker.ports")
    private let lock = OSAllocatedUnfairLock(initialState: [String: Live]())

    func publish(
        key: String,
        hostIP: String,
        hostPort: Int,
        containerIP: String,
        containerPort: Int
    ) async throws -> Int {
        guard (0...65535).contains(hostPort), (1...65535).contains(containerPort) else {
            throw EngineError.invalidArgument("invalid port mapping \(hostPort):\(containerPort)")
        }
        guard !containerIP.isEmpty else {
            throw EngineError.invalidArgument("cannot publish ports before the container has an IP")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try Self.makeListener(parameters: parameters, hostIP: hostIP, hostPort: hostPort)
        } catch {
            throw EngineError.conflict("failed to bind \(Self.displayHost(hostIP)):\(hostPort): \(error.localizedDescription)")
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
                            "failed to listen on \(Self.displayHost(hostIP)):\(hostPort): \(error.localizedDescription)"
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
            self?.bridge(incoming, key: key, to: containerIP, port: containerPort)
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

    private func bridge(_ incoming: NWConnection, key: String, to containerIP: String, port: Int) {
        guard let targetPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            incoming.cancel()
            return
        }
        let outgoing = NWConnection(host: NWEndpoint.Host(containerIP), port: targetPort, using: .tcp)
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
        remember(incoming, key: key)
        remember(outgoing, key: key)
        pipe(incoming, to: outgoing)
        pipe(outgoing, to: incoming)
    }

    private func cancel(_ live: Live) {
        live.listener.cancel()
        for connection in live.connections.values {
            connection.cancel()
        }
    }

    private func pipe(_ from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            let publisher = self
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in
                    if error == nil, !isComplete {
                        publisher?.pipe(from, to: to)
                    }
                })
            }
            if isComplete || error != nil {
                to.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    from.cancel()
                    to.cancel()
                })
            }
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
