import Containerization
import Foundation

import struct ContainerizationOS.Terminal

/// Fan-out target for live container output.
struct EngineIOSubscriber: Sendable {
    enum Kind: Sendable {
        /// Live stdio. TTY stays close to the PTY; includes the Docker exit notice.
        case attach
        /// `logs -f`. TTY is cooked so DSR queries never hit the client's terminal.
        case logs
    }

    let continuation: AsyncStream<EngineIOChunk>.Continuation
    let kind: Kind
}

extension EngineManager {
    public func resizeContainer(_ idOrName: String, height: Int, width: Int) async throws {
        let container = try resolveContainer(idOrName)
        guard container.tty, height > 0, width > 0, let linux = vms[container.id] else { return }
        try await linux.resize(
            to: Terminal.Size(width: UInt16(clamping: width), height: UInt16(clamping: height))
        )
    }

    public func attachContainer(
        _ idOrName: String,
        logs: Bool,
        stream: Bool,
        stdin: Bool
    ) async throws -> EngineIOSession {
        let container = try resolveContainer(idOrName)
        guard logs || stream || stdin else {
            throw EngineError.invalidArgument("you must choose at least one of logs, stream or stdin")
        }

        let replay: [EngineIOChunk]
        if logs, !container.logs.isEmpty {
            replay = [EngineIOChunk(data: Data(container.logs.utf8), stdout: true)]
        } else {
            replay = []
        }

        let keepOpen = stream || stdin
        if keepOpen {
            if container.state == "paused" {
                throw EngineError.conflict("You cannot attach to a paused container, unpause it first")
            }
            if container.state == "exited" || container.state == "dead" {
                throw EngineError.conflict("You cannot attach to a stopped container, start it first")
            }
            let session = subscribeAttach(
                containerID: container.id,
                tty: container.tty,
                stdin: stdin && container.openStdin,
                kind: .attach,
                replay: replay
            )
            await publish(
                EngineEvent(
                    type: "container",
                    action: "attach",
                    actorID: container.id,
                    attributes: ["name": container.name]
                )
            )
            return session
        }

        return finishedSession(containerID: container.id, tty: container.tty, replay: replay)
    }

    func subscribeAttach(
        containerID: String,
        tty: Bool,
        stdin: Bool,
        kind: EngineIOSubscriber.Kind,
        replay: [EngineIOChunk] = []
    ) -> EngineIOSession {
        let sessionID = UUID()
        let (chunks, continuation) = AsyncStream<EngineIOChunk>.makeStream()
        for chunk in replay {
            continuation.yield(chunk)
        }
        attachSubscribers[containerID, default: [:]][sessionID] = EngineIOSubscriber(
            continuation: continuation,
            kind: kind
        )
        return ioSession(
            containerID: containerID,
            sessionID: sessionID,
            tty: tty,
            stdin: stdin,
            chunks: chunks
        )
    }

    private func finishedSession(
        containerID: String,
        tty: Bool,
        replay: [EngineIOChunk]
    ) -> EngineIOSession {
        let sessionID = UUID()
        let (chunks, continuation) = AsyncStream<EngineIOChunk>.makeStream()
        for chunk in replay {
            continuation.yield(chunk)
        }
        continuation.finish()
        return ioSession(
            containerID: containerID,
            sessionID: sessionID,
            tty: tty,
            stdin: false,
            chunks: chunks
        )
    }

    private func ioSession(
        containerID: String,
        sessionID: UUID,
        tty: Bool,
        stdin: Bool,
        chunks: AsyncStream<EngineIOChunk>
    ) -> EngineIOSession {
        let engine = self
        return EngineIOSession(
            tty: tty,
            stdin: stdin,
            chunks: chunks,
            writeStdin: { data in
                await engine.writeAttachStdin(containerID, data: data)
            },
            close: {
                await engine.closeAttach(containerID, sessionID: sessionID)
            }
        )
    }

    func writeAttachStdin(_ containerID: String, data: Data) {
        containerStdin[containerID]?.yield(data)
    }

    func closeAttach(_ containerID: String, sessionID: UUID) {
        if let subscriber = attachSubscribers[containerID]?.removeValue(forKey: sessionID) {
            subscriber.continuation.finish()
        }
        if attachSubscribers[containerID]?.isEmpty == true {
            attachSubscribers[containerID] = nil
        }
    }

    func finishAttachSubscribers(_ containerID: String, extra: String?) {
        let subscribers = attachSubscribers.removeValue(forKey: containerID) ?? [:]
        for subscriber in subscribers.values {
            if subscriber.kind == .attach, let extra, !extra.isEmpty {
                subscriber.continuation.yield(EngineIOChunk(data: Data(extra.utf8), stdout: true))
            }
            subscriber.continuation.finish()
        }
    }
}
