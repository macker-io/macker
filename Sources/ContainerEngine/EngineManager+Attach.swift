import Containerization
import Foundation

import struct ContainerizationOS.Terminal

/// Fan-out target for live container output.
struct EngineIOSubscriber: Sendable {
    enum Kind: Sendable {
        /// Live stdio. TTY stays close to the PTY.
        case attach
        /// `logs -f`: one chunk per log line (with its time). TTY is cooked so DSR queries
        /// never hit the client's terminal.
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

        let keepOpen = stream || stdin
        let replay = attachReplay(container, includeLogs: logs, includeCurrentLine: keepOpen)
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
            await publish(containerEvent("attach", container))
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

    /// Historical logs, then the in-progress TTY line. Live attach only sees
    /// bytes that arrive after subscribe, so without this replay a reattach
    /// sits blank until the shell prints again.
    private func attachReplay(
        _ container: EngineContainer,
        includeLogs: Bool,
        includeCurrentLine: Bool
    ) -> [EngineIOChunk] {
        var chunks: [EngineIOChunk] = []
        if includeLogs {
            chunks += container.logs.map {
                EngineIOChunk(data: Data($0.text.utf8), stdout: $0.stdout, time: $0.time)
            }
        }
        if includeCurrentLine, container.tty, let line = ttySessions[container.id]?.currentLine, !line.isEmpty {
            chunks.append(EngineIOChunk(data: line, stdout: true))
        }
        return chunks
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
            closeStdin: {
                await engine.closeAttachStdin(containerID)
            },
            close: {
                await engine.closeAttach(containerID, sessionID: sessionID)
            }
        )
    }

    func writeAttachStdin(_ containerID: String, data: Data) {
        attachStdinPipe(containerID)?.yield(data)
    }

    /// Docker closes the container's stdin when an attached client ends its stdin and the
    /// container was created with `StdinOnce`; otherwise only that client stops sending.
    func closeAttachStdin(_ containerID: String) {
        guard containers[containerID]?.stdinOnce == true else { return }
        attachStdinPipe(containerID)?.finish()
    }

    /// The running process's stdin, or (before `start` / `start -a`) a pipe that `bootContainer` will
    /// hand to the process, so input sent between attach and start is not lost.
    private func attachStdinPipe(_ containerID: String) -> ProcessStdin? {
        if let pipe = containerStdin[containerID] {
            return pipe
        }
        guard let container = containers[containerID], container.openStdin, !container.isActive else {
            return nil
        }
        let pipe = ProcessStdin()
        containerStdin[containerID] = pipe
        return pipe
    }

    func closeAttach(_ containerID: String, sessionID: UUID) {
        if let subscriber = attachSubscribers[containerID]?.removeValue(forKey: sessionID) {
            subscriber.continuation.finish()
        }
        if attachSubscribers[containerID]?.isEmpty == true {
            attachSubscribers[containerID] = nil
        }
    }

    func finishAttachSubscribers(_ containerID: String) {
        let subscribers = attachSubscribers.removeValue(forKey: containerID) ?? [:]
        for subscriber in subscribers.values {
            subscriber.continuation.finish()
        }
    }
}
