import Containerization
import Foundation

import struct ContainerizationOS.Terminal

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

        let sessionID = UUID()
        let (chunks, continuation) = AsyncStream<EngineIOChunk>.makeStream()
        if logs, !container.logs.isEmpty {
            continuation.yield(EngineIOChunk(data: Data(container.logs.utf8), stdout: true))
        }

        let keepOpen = stream || stdin
        if keepOpen {
            attachSubscribers[container.id, default: [:]][sessionID] = continuation
            await publish(
                EngineEvent(
                    type: "container",
                    action: "attach",
                    actorID: container.id,
                    attributes: ["name": container.name]
                )
            )
        } else {
            continuation.finish()
        }

        let engine = self
        let containerID = container.id
        return EngineIOSession(
            tty: container.tty,
            stdin: stdin && container.openStdin,
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
        if let continuation = attachSubscribers[containerID]?.removeValue(forKey: sessionID) {
            continuation.finish()
        }
        if attachSubscribers[containerID]?.isEmpty == true {
            attachSubscribers[containerID] = nil
        }
    }

    func finishAttachSubscribers(_ containerID: String, extra: String?) {
        let subscribers = attachSubscribers.removeValue(forKey: containerID) ?? [:]
        for continuation in subscribers.values {
            if let extra, !extra.isEmpty {
                continuation.yield(EngineIOChunk(data: Data(extra.utf8), stdout: true))
            }
            continuation.finish()
        }
    }
}
