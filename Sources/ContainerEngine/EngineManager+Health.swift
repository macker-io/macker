import Containerization
import Foundation

extension EngineManager {
    func startHealthMonitor(_ id: String) {
        cancelHealthMonitor(id)
        guard var container = containers[id],
            let spec = container.run.healthcheck,
            !spec.isDisabled,
            spec.command != nil
        else { return }
        container.health = EngineHealthState(status: "starting")
        saveContainer(container)
        healthTasks[id] = Task { await self.healthLoop(id, spec: spec) }
    }

    func cancelHealthMonitor(_ id: String) {
        healthTasks[id]?.cancel()
        healthTasks[id] = nil
    }

    private func healthLoop(_ id: String, spec: EngineHealthcheck) async {
        while !Task.isCancelled {
            guard let container = try? resolveContainer(id), container.state == "running" else { return }
            let startedAt = container.startedAt ?? container.created
            let delay = Date().timeIntervalSince(startedAt) < spec.startPeriod ? spec.startInterval : spec.interval
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard (try? resolveContainer(id))?.state == "running" else { return }
            let entry = await probeHealth(id, spec: spec)
            await applyHealthResult(id, spec: spec, entry: entry)
        }
    }

    private func probeHealth(_ id: String, spec: EngineHealthcheck) async -> EngineHealthLog {
        let start = Date()
        guard let command = spec.command else {
            return EngineHealthLog(start: start, end: Date(), exitCode: -1, output: "no health command")
        }
        let (code, output) = await runHealthCommand(id, command: command, timeout: spec.timeout)
        return EngineHealthLog(start: start, end: Date(), exitCode: code, output: output)
    }

    private func applyHealthResult(_ id: String, spec: EngineHealthcheck, entry: EngineHealthLog) async {
        guard var container = try? resolveContainer(id), container.state == "running" else { return }
        var health = container.health ?? EngineHealthState(status: "starting")
        health.append(entry)
        health.apply(exitCode: entry.exitCode, startedAt: container.startedAt ?? container.created, spec: spec)
        let changed = container.health?.status != health.status
        container.health = health
        saveContainer(container)
        if changed {
            await publish(
                EngineEvent(
                    type: "container",
                    action: "health_status",
                    actorID: id,
                    attributes: ["healthStatus": health.status]
                )
            )
        }
    }

    private func runHealthCommand(
        _ containerID: String,
        command: [String],
        timeout: TimeInterval
    ) async -> (code: Int, output: String) {
        guard let linux = vms[containerID], let container = try? resolveContainer(containerID) else {
            return (-1, "container is not running")
        }
        let processID = "hc-\(String(Self.makeContainerID().prefix(12)))"
        let lock = OutputBox()
        let sink = ProcessLogSink { data in
            lock.append(data)
        }
        var started: LinuxProcess?
        do {
            let process = try await linux.exec(processID) { config in
                config.arguments = command
                config.environmentVariables = Self.mergedEnvironment(container.env, tty: false)
                if !container.workingDir.isEmpty {
                    config.workingDirectory = container.workingDir
                }
                if !container.user.isEmpty {
                    config.user = .init(username: container.user)
                }
                config.terminal = false
                config.stdout = sink
                config.stderr = sink
            }
            started = process
            try await process.start()
            let code = try await Self.wait(process, timeout: timeout)
            try? await process.delete()
            return (code, lock.text())
        } catch {
            if let process = started {
                try? await process.kill(.kill)
                try? await process.delete()
            }
            return (-1, error.localizedDescription)
        }
    }

    private static func wait(_ process: LinuxProcess, timeout: TimeInterval) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                Int(try await process.wait().exitCode)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw HealthTimeout()
            }
            do {
                let code = try await group.next()!
                group.cancelAll()
                return code
            } catch is HealthTimeout {
                group.cancelAll()
                try? await process.kill(.kill)
                return -1
            }
        }
    }
}

private struct HealthTimeout: Error {}

private final class OutputBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > EngineHealthcheck.maxOutputBytes {
            data = data.suffix(EngineHealthcheck.maxOutputBytes)
        }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
