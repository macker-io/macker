import Foundation

extension EngineManager {
    public func createExec(_ idOrName: String, spec: EngineExecCreateSpec) async throws -> String {
        let container = try resolveContainer(idOrName)
        if container.state == "paused" {
            throw EngineError.conflict("Container \(container.id) is paused, unpause the container before exec")
        }
        guard !spec.cmd.isEmpty else {
            throw EngineError.invalidArgument("No exec command specified")
        }
        let id = Self.makeContainerID()
        execs[id] = EngineExec(
            id: id,
            containerID: container.id,
            cmd: spec.cmd,
            env: spec.env,
            user: spec.user.isEmpty ? container.user : spec.user,
            workingDir: spec.workingDir.isEmpty ? container.workingDir : spec.workingDir,
            tty: spec.tty,
            privileged: spec.privileged,
            attachStdin: spec.attachStdin,
            attachStdout: spec.attachStdout,
            attachStderr: spec.attachStderr,
            detachKeys: spec.detachKeys,
            started: false,
            running: false,
            exitCode: nil,
            pid: 0,
            height: 0,
            width: 0
        )
        await publish(
            EngineEvent(
                type: "container",
                action: "exec_create",
                actorID: container.id,
                attributes: ["name": container.name, "execID": id, "execCommand": spec.cmd.joined(separator: " ")]
            )
        )
        return id
    }

    public func inspectExec(_ id: String) async throws -> EngineExec {
        try resolveExec(id)
    }

    public func resizeExec(_ id: String, height: Int, width: Int) async throws {
        var exec = try resolveExec(id)
        exec.height = height
        exec.width = width
        execs[id] = exec
    }

    public func startExec(_ id: String, detach: Bool, tty: Bool?) async throws -> EngineIOSession? {
        var exec = try resolveExec(id)
        if exec.started {
            throw EngineError.conflict("exec \(id) has already started")
        }
        let container = try resolveContainer(exec.containerID)
        if container.state == "paused" {
            throw EngineError.conflict("Container \(container.id) is paused, unpause the container before exec")
        }
        guard container.state == "running" else {
            throw EngineError.conflict("Container \(container.id) is not running")
        }
        if let tty {
            exec.tty = tty
        }
        exec.started = true
        exec.running = true
        exec.pid = 1
        execs[id] = exec
        await publish(
            EngineEvent(
                type: "container",
                action: "exec_start",
                actorID: container.id,
                attributes: ["name": container.name, "execID": id]
            )
        )

        let banner = "[macker] exec \(exec.cmd.joined(separator: " ")) — MicroVM not wired\n"
        if detach {
            await completeExec(id, code: 0)
            return nil
        }

        let sessionID = UUID()
        let (chunks, continuation) = AsyncStream<String>.makeStream()
        execSubscribers[id, default: [:]][sessionID] = continuation
        if exec.attachStdout || exec.attachStderr || exec.tty {
            continuation.yield(banner)
        }

        if !exec.attachStdin {
            await completeExec(id, code: 0)
        }

        let engine = self
        return EngineIOSession(
            tty: exec.tty,
            chunks: chunks,
            writeStdin: { data in
                await engine.writeExecStdin(id, data: data)
            },
            close: {
                await engine.completeExec(id, code: 0)
            }
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
        let (chunks, continuation) = AsyncStream<String>.makeStream()
        if logs, !container.logs.isEmpty {
            continuation.yield(container.logs)
        }

        let keepOpen = (stream || stdin) && (container.state == "running" || container.state == "paused")
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
            chunks: chunks,
            writeStdin: { data in
                await engine.writeAttachStdin(containerID, data: data)
            },
            close: {
                await engine.closeAttach(containerID, sessionID: sessionID)
            }
        )
    }

    func writeExecStdin(_ id: String, data: Data) {
        guard let exec = execs[id], exec.running else { return }
        guard exec.attachStdout || exec.tty else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        if let subscribers = execSubscribers[id] {
            for continuation in subscribers.values {
                continuation.yield(text)
            }
        }
    }

    func writeAttachStdin(_ containerID: String, data: Data) {
        _ = containerID
        _ = data
    }

    func closeAttach(_ containerID: String, sessionID: UUID) {
        if let continuation = attachSubscribers[containerID]?.removeValue(forKey: sessionID) {
            continuation.finish()
        }
        if attachSubscribers[containerID]?.isEmpty == true {
            attachSubscribers[containerID] = nil
        }
    }

    func completeExec(_ id: String, code: Int) async {
        guard var exec = execs[id] else { return }
        let wasRunning = exec.running
        if exec.started {
            exec.running = false
            if exec.exitCode == nil {
                exec.exitCode = code
            }
            execs[id] = exec
        }
        finishExecSubscribers(id)
        if wasRunning {
            await publish(
                EngineEvent(
                    type: "container",
                    action: "exec_die",
                    actorID: exec.containerID,
                    attributes: ["execID": id, "exitCode": "\(code)"]
                )
            )
        }
    }

    func finishExecs(forContainer containerID: String, code: Int) async {
        let ids = execs.values.filter { $0.containerID == containerID && $0.running }.map(\.id)
        for id in ids {
            await completeExec(id, code: code)
        }
    }

    func finishAttachSubscribers(_ containerID: String, extra: String?) {
        let subscribers = attachSubscribers.removeValue(forKey: containerID) ?? [:]
        for continuation in subscribers.values {
            if let extra, !extra.isEmpty {
                continuation.yield(extra)
            }
            continuation.finish()
        }
    }

    private func finishExecSubscribers(_ id: String) {
        let subscribers = execSubscribers.removeValue(forKey: id) ?? [:]
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    private func resolveExec(_ id: String) throws -> EngineExec {
        if let exec = execs[id] {
            return exec
        }
        if let exec = execs.values.first(where: { $0.id.hasPrefix(id) }) {
            return exec
        }
        throw EngineError.execNotFound("No such exec instance: \(id)")
    }
}
