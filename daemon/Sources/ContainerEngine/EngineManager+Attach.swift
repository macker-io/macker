import Containerization
import Foundation

import struct ContainerizationOS.Terminal

/// Fan-out target for live container output. Attach gets the Docker exit notice; `logs -f` does not.
struct EngineIOSubscriber: Sendable {
    let continuation: AsyncStream<EngineIOChunk>.Continuation
    let includeExitNotice: Bool
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

        var replay: [EngineIOChunk] = []
        if logs, !container.logs.isEmpty {
            replay.append(EngineIOChunk(data: Data(container.logs.utf8), stdout: true))
        }

        let keepOpen = stream || stdin
        if keepOpen {
            let session = subscribeAttach(
                containerID: container.id,
                tty: container.tty,
                stdin: stdin && container.openStdin,
                includeExitNotice: true,
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

        let sessionID = UUID()
        let (chunks, continuation) = AsyncStream<EngineIOChunk>.makeStream()
        for chunk in replay {
            continuation.yield(chunk)
        }
        continuation.finish()
        return ioSession(
            containerID: container.id,
            sessionID: sessionID,
            tty: container.tty,
            stdin: false,
            chunks: chunks
        )
    }

    func subscribeAttach(
        containerID: String,
        tty: Bool,
        stdin: Bool,
        includeExitNotice: Bool,
        replay: [EngineIOChunk] = []
    ) -> EngineIOSession {
        let sessionID = UUID()
        let (chunks, continuation) = AsyncStream<EngineIOChunk>.makeStream()
        for chunk in replay {
            continuation.yield(chunk)
        }
        attachSubscribers[containerID, default: [:]][sessionID] = EngineIOSubscriber(
            continuation: continuation,
            includeExitNotice: includeExitNotice
        )
        return ioSession(
            containerID: containerID,
            sessionID: sessionID,
            tty: tty,
            stdin: stdin,
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
            if subscriber.includeExitNotice, let extra, !extra.isEmpty {
                subscriber.continuation.yield(EngineIOChunk(data: Data(extra.utf8), stdout: true))
            }
            subscriber.continuation.finish()
        }
    }
}
