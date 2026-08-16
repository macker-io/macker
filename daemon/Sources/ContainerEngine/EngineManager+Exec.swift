import Containerization
import Foundation

import struct ContainerizationOS.Terminal

extension EngineManager {
    public func createExec(_ idOrName: String, spec: EngineExecCreateSpec) async throws -> String {
        let container = try requireRunningForExec(idOrName)
        guard !spec.cmd.isEmpty else {
            throw EngineError.invalidArgument("No exec command specified")
        }
        let id = Self.makeContainerID()
        execs[id] = EngineExec(id: id, container: container, spec: spec)
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
        guard let process = execProcesses[id] else { return }
        try await Self.resize(process, width: width, height: height)
    }

    public func killExec(_ id: String, signal: String) async throws {
        let exec = try resolveExec(id)
        guard exec.started, exec.running, let process = execProcesses[id] else {
            throw EngineError.conflict("exec \(id) is not running")
        }
        try await process.kill(Self.parsedKillSignal(signal))
    }

    public func startExec(_ id: String, detach: Bool, tty: Bool?) async throws -> EngineIOSession? {
        var exec = try resolveExec(id)
        if exec.started {
            throw EngineError.conflict("exec \(id) has already started")
        }
        if let tty {
            exec.tty = tty
        }
        let container = try requireRunningForExec(exec.containerID)
        guard let linux = vms[container.id] else {
            throw EngineError.conflict("Container \(container.id) has no running MicroVM")
        }

        let stdinPipe = exec.attachStdin ? ProcessStdin() : nil
        let stdoutSink = ProcessLogSink(hopping: { [id] data in
            await self.yieldExecOutput(id, data: data, stdout: true)
        })
        let stderrSink = ProcessLogSink(hopping: { [id] data in
            await self.yieldExecOutput(id, data: data, stdout: false)
        })

        // Subscribe before start() so the first PTY bytes (dash/ash `# `) are not dropped.
        var chunks: AsyncStream<EngineIOChunk>?
        if !detach {
            let stream = AsyncStream<EngineIOChunk>.makeStream()
            chunks = stream.stream
            execSubscribers[id, default: [:]][UUID()] = stream.continuation
        }

        let execConfig = exec
        var started: LinuxProcess?
        do {
            let process = try await linux.exec(execConfig.id) { config in
                Self.configure(&config, exec: execConfig, container: container, stdin: stdinPipe, stdout: stdoutSink, stderr: stderrSink)
            }
            started = process
            try await process.start()
        } catch {
            stdinPipe?.finish()
            if !detach {
                finishExecSubscribers(id)
            }
            try? await started?.delete()
            throw EngineError.runtimeUnavailable(Self.describeExecFailure(error, command: execConfig.cmd))
        }
        guard let process = started else {
            throw EngineError.runtimeUnavailable("unable to start exec process")
        }

        exec.started = true
        exec.running = true
        exec.pid = Int(process.pid)
        execs[id] = exec
        execProcesses[id] = process
        if let stdinPipe {
            execStdin[id] = stdinPipe
        }
        if exec.tty {
            try? await Self.resize(
                process,
                width: exec.width > 0 ? exec.width : 80,
                height: exec.height > 0 ? exec.height : 24
            )
        }
        await publish(
            EngineEvent(
                type: "container",
                action: "exec_start",
                actorID: container.id,
                attributes: ["name": container.name, "execID": id]
            )
        )

        execWaitTasks[id] = Task { [process] in
            let code: Int
            do {
                code = Int(try await process.wait().exitCode)
            } catch is CancellationError {
                try? await process.delete()
                return
            } catch {
                code = 137
            }
            await self.completeExec(id, code: code, fromWait: true)
            try? await process.delete()
        }

        guard let chunks else { return nil }
        let engine = self
        return EngineIOSession(
            tty: exec.tty,
            stdin: exec.attachStdin,
            chunks: chunks,
            writeStdin: { data in
                await engine.writeExecStdin(id, data: data)
            },
            close: {
                await engine.closeExecStdin(id)
            }
        )
    }

    func writeExecStdin(_ id: String, data: Data) {
        execStdin[id]?.yield(data)
    }

    func closeExecStdin(_ id: String) async {
        execStdin[id]?.finish()
        if let process = execProcesses[id] {
            try? await process.closeStdin()
        }
    }

    func completeExec(_ id: String, code: Int, fromWait: Bool = false) async {
        guard var exec = execs[id] else {
            cleanupExecIO(id)
            return
        }
        let wasRunning = exec.running
        if exec.started {
            exec.running = false
            if exec.exitCode == nil {
                exec.exitCode = code
            }
            execs[id] = exec
        }
        if !fromWait, let process = execProcesses[id] {
            try? await process.kill(.kill)
        }
        cleanupExecIO(id)
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
            if let process = execProcesses[id] {
                try? await process.kill(.kill)
            }
            execStdin[id]?.finish()
            if execWaitTasks[id] == nil {
                await completeExec(id, code: code, fromWait: true)
            }
        }
    }

    func yieldExecOutput(_ id: String, data: Data, stdout: Bool) {
        guard !data.isEmpty, let exec = execs[id] else { return }
        if exec.tty {
            guard exec.attachStdout || exec.attachStderr else { return }
        } else if stdout {
            guard exec.attachStdout else { return }
        } else {
            guard exec.attachStderr else { return }
        }
        guard let subscribers = execSubscribers[id] else { return }
        let chunk = EngineIOChunk(data: data, stdout: stdout)
        for continuation in subscribers.values {
            continuation.yield(chunk)
        }
    }

    static func mergedEnvironment(_ base: [String], extra: [String] = [], tty: Bool) -> [String] {
        var map: [String: String] = [:]
        var order: [String] = []
        func put(_ item: String) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard !key.isEmpty else { return }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if map[key] == nil {
                order.append(key)
            }
            map[key] = value
        }
        for item in base { put(item) }
        for item in extra { put(item) }
        if map["PATH"] == nil {
            order.insert("PATH", at: 0)
            map["PATH"] = LinuxProcessConfiguration.defaultPath
        }
        if tty, map["TERM"] == nil {
            order.append("TERM")
            map["TERM"] = "xterm"
        }
        return order.map { "\($0)=\(map[$0]!)" }
    }

    func requireRunningForExec(_ idOrName: String) throws -> EngineContainer {
        let container = try resolveContainer(idOrName)
        if container.state == "paused" {
            throw EngineError.conflict("Container \(container.id) is paused, unpause the container before exec")
        }
        guard container.state == "running" else {
            throw EngineError.conflict("Container \(container.id) is not running")
        }
        return container
    }

    static func describeExecFailure(_ error: Error, command: [String] = []) -> String {
        let raw = error.localizedDescription
        if raw.contains("failed to find target executable") {
            let exe = command.first ?? "unknown"
            return "exec: \"\(exe)\": executable file not found in $PATH"
        }
        return "unable to start exec process: \(raw)"
    }

    private static func configure(
        _ config: inout LinuxProcessConfiguration,
        exec: EngineExec,
        container: EngineContainer,
        stdin: ProcessStdin?,
        stdout: ProcessLogSink,
        stderr: ProcessLogSink
    ) {
        config.arguments = exec.cmd
        config.environmentVariables = mergedEnvironment(container.env, extra: exec.env, tty: exec.tty)
        if !exec.workingDir.isEmpty {
            config.workingDirectory = exec.workingDir
        }
        if !exec.user.isEmpty {
            config.user = .init(username: exec.user)
        }
        config.terminal = exec.tty
        if exec.privileged {
            config.capabilities = .allCapabilities
        }
        if let stdin {
            config.stdin = stdin
        }
        config.stdout = stdout
        if !exec.tty {
            config.stderr = stderr
        }
    }

    private static func resize(_ process: LinuxProcess, width: Int, height: Int) async throws {
        guard width > 0, height > 0 else { return }
        try await process.resize(
            to: Terminal.Size(width: UInt16(clamping: width), height: UInt16(clamping: height))
        )
    }

    private func cleanupExecIO(_ id: String) {
        execWaitTasks[id] = nil
        execStdin[id]?.finish()
        execStdin[id] = nil
        execProcesses[id] = nil
        finishExecSubscribers(id)
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
