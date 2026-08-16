import Containerization
import Foundation

extension EngineManager {
    /// Runs a command in the guest and captures stdout. Does not create a Docker exec instance.
    func runGuest(_ idOrName: String, command: [String]) async throws -> (code: Int, stdout: String) {
        let container = try requireRunningForExec(idOrName)
        guard let linux = vms[container.id] else {
            throw EngineError.conflict("Container \(container.id) has no running MicroVM")
        }
        let collector = DataCollector()
        let stdout = ProcessLogSink { collector.append($0) }
        let stderr = ProcessLogSink { _ in }
        let processID = Self.makeContainerID()
        let process: LinuxProcess
        do {
            process = try await linux.exec(processID) { config in
                config.arguments = command
                config.environmentVariables = Self.mergedEnvironment(container.env, tty: false)
                config.terminal = false
                config.stdout = stdout
                config.stderr = stderr
            }
            try await process.start()
        } catch {
            throw EngineError.runtimeUnavailable(Self.describeExecFailure(error, command: command))
        }
        let code: Int
        do {
            code = try await Self.waitGuest(process, seconds: 8)
        } catch {
            try? await process.kill(.kill)
            _ = try? await process.wait()
            try? await process.delete()
            throw error
        }
        try? await process.delete()
        let text = String(decoding: collector.snapshot(), as: UTF8.self)
        return (code, text)
    }

    func readGuestSnapshot(_ id: String) async throws -> GuestProc.Snapshot {
        let result = try await runGuest(id, command: ["sh", "-c", GuestProc.dumpScript])
        guard let snapshot = GuestProc.parseDump(result.stdout) else {
            throw EngineError.runtimeUnavailable("unable to read guest resource stats")
        }
        return snapshot
    }

    func readGuestProcessTable(_ id: String) async throws -> EngineContainerTop {
        let result = try await runGuest(id, command: ["sh", "-c", GuestProc.topScript])
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.runtimeUnavailable("unable to read guest process table")
        }
        return GuestProc.parseTop(result.stdout)
    }

    /// Guest path of the container rootfs. Same as `LinuxContainer.guestRootfsPath` (private).
    static func guestRootfsPath(_ id: String) -> String {
        "/run/container/\(id)/rootfs"
    }

    func withGuestAgent<T: Sendable>(_ id: String, _ body: @Sendable (Vminitd) async throws -> T) async throws -> T {
        guard let linux = vms[id] else {
            throw EngineError.conflict("container \(id) has no running MicroVM")
        }
        return try await linux.withVirtualMachineInstance { vm in
            guard let vz = vm as? VZVirtualMachineInstance else {
                throw EngineError.runtimeUnavailable("guest agent is unavailable")
            }
            let agent = try await vz.dialAgent()
            do {
                let result = try await body(agent)
                try await agent.close()
                return result
            } catch {
                try? await agent.close()
                throw error
            }
        }
    }
}

private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

extension EngineManager {
    private static func waitGuest(_ process: LinuxProcess, seconds: Int) async throws -> Int {
        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                Int(try await process.wait().exitCode)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw EngineError.runtimeUnavailable("timed out waiting for guest command")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
