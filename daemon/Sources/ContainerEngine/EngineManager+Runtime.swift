import Containerization
import ContainerizationOCI
import Foundation

extension EngineManager {
    static let defaultMemoryBytes: UInt64 = 1_073_741_824
    static let defaultRootfsBytes: UInt64 = 1_073_741_824

    /// Kernel / initfs presence without downloading anything.
    public func runtimeStatus() async -> RuntimeStatus {
        let images = (try? await imageStore.list()) ?? []
        let vminitPresent = images.contains { $0.reference.contains("vminit") }
        return RuntimeAssets.inspect(storePath: imageStore.path, vminitPresent: vminitPresent)
    }

    /// Downloads the Kata kernel and pulls `vminit` if they are not already local.
    public func prepareRuntime() async throws -> RuntimeStatus {
        let status = try await RuntimeAssets.prepare(store: imageStore)
        containerManager = nil
        return status
    }

    /// Fetches the pinned runtime and copies `vmlinux` + `initfs.ext4` into `output`.
    public func stageRuntime(to output: URL) async throws -> RuntimeStatus {
        let status = try await prepareRuntime()
        try RuntimeAssets.stage(status: status, to: output)
        return status
    }

    func bootContainer(_ record: EngineContainer) async throws {
        let image = try await resolveImage(record.image)
        var manager = try await ensureManager()
        resetContainerFiles(record.id)

        let sink = ProcessLogSink { [id = record.id] text in
            Task { await self.appendOutput(id: id, text: text) }
        }

        var linux: LinuxContainer?
        do {
            let created = try await manager.create(
                record.id,
                image: image,
                rootfsSizeInBytes: Self.defaultRootfsBytes,
                networking: false
            ) { config in
                if !record.command.isEmpty {
                    config.process.arguments = record.command
                }
                if !record.env.isEmpty {
                    config.process.environmentVariables = record.env
                }
                if !record.workingDir.isEmpty {
                    config.process.workingDirectory = record.workingDir
                }
                if !record.user.isEmpty {
                    config.process.user = .init(username: record.user)
                }
                config.process.terminal = record.tty
                config.process.stdout = sink
                if !record.tty {
                    config.process.stderr = sink
                }
                config.hostname = record.hostname
                config.cpus = Self.cpuCount(nanoCpus: record.nanoCpus)
                config.memoryInBytes = record.memory > 0 ? UInt64(record.memory) : Self.defaultMemoryBytes
                for mount in record.mounts where !mount.source.isEmpty && !mount.destination.isEmpty {
                    var options: [String] = []
                    if !mount.rw {
                        options.append("ro")
                    }
                    config.mounts.append(.share(source: mount.source, destination: mount.destination, options: options))
                }
            }
            linux = created
            containerManager = manager
            try await created.create()
            try await created.start()
        } catch {
            try? await linux?.stop()
            vms[record.id] = nil
            resetContainerFiles(record.id)
            throw EngineError.runtimeUnavailable("failed to start MicroVM: \(error.localizedDescription)")
        }

        guard let linux else {
            throw EngineError.runtimeUnavailable("failed to start MicroVM")
        }
        vms[record.id] = linux
    }

    func watchVM(_ id: String) {
        guard let linux = vms[id] else { return }
        waitTasks[id]?.cancel()
        waitTasks[id] = Task {
            let result: Result<Int, Error>
            do {
                result = .success(Int(try await linux.wait().exitCode))
            } catch {
                result = .failure(error)
            }
            await self.finishWatchedVM(id: id, result: result)
        }
    }

    func finishWatchedVM(id: String, result: Result<Int, Error>) async {
        guard waitTasks.removeValue(forKey: id) != nil else { return }
        switch result {
        case .success(let code):
            await handleVMExit(id: id, code: code, action: "die")
        case .failure(let error) where error is CancellationError:
            return
        case .failure:
            await handleVMExit(id: id, code: 137, action: "die")
        }
    }

    func stopVM(_ id: String, timeoutSeconds: Int, signal: Signal = .term) async {
        guard let linux = vms[id] else { return }
        waitTasks[id]?.cancel()
        waitTasks[id] = nil
        try? await linux.kill(signal)
        do {
            _ = try await linux.wait(timeoutInSeconds: Int64(max(timeoutSeconds, 1)))
        } catch {
            try? await linux.kill(.kill)
            _ = try? await linux.wait(timeoutInSeconds: 2)
        }
        await teardownVM(id)
    }

    func teardownVM(_ id: String) async {
        waitTasks[id]?.cancel()
        waitTasks[id] = nil
        if let linux = vms.removeValue(forKey: id) {
            try? await linux.stop()
        }
    }

    func handleVMExit(id: String, code: Int, action: String) async {
        await teardownVM(id)
        guard var record = containers[id] else { return }
        guard record.state == "running" || record.state == "paused" else { return }
        if record.autoRemove {
            resetContainerFiles(id)
        }
        try? await finish(container: &record, exitCode: code, action: action, status: "Exited (\(code))")
    }

    func appendOutput(id: String, text: String) {
        guard !text.isEmpty else { return }
        if var record = containers[id] {
            record.logs += text
            containers[id] = record
        }
        if let subscribers = attachSubscribers[id] {
            for continuation in subscribers.values {
                continuation.yield(text)
            }
        }
    }

    func resetContainerFiles(_ id: String) {
        try? containerManager?.releaseNetwork(id)
        let path = imageStore.path.appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
    }

    func pauseVM(_ id: String) async throws {
        guard let linux = vms[id] else {
            throw EngineError.conflict("container \(id) has no running MicroVM")
        }
        try await linux.withVirtualMachineInstance { vm in
            try await vm.pause()
        }
    }

    func resumeVM(_ id: String) async throws {
        guard let linux = vms[id] else {
            throw EngineError.conflict("container \(id) has no running MicroVM")
        }
        try await linux.withVirtualMachineInstance { vm in
            try await vm.resume()
        }
    }

    private func ensureManager() async throws -> ContainerManager {
        if let containerManager {
            return containerManager
        }
        _ = try await RuntimeAssets.prepare(store: imageStore)
        let kernel = try RuntimeAssets.kernel(storePath: imageStore.path)
        let initfs = try RuntimeAssets.initfsMount(storePath: imageStore.path)
        let manager = try ContainerManager(
            kernel: kernel,
            initfs: initfs,
            imageStore: imageStore,
            network: nil
        )
        containerManager = manager
        return manager
    }

    private static func cpuCount(nanoCpus: Int64) -> Int {
        guard nanoCpus > 0 else { return 2 }
        return max(1, Int((nanoCpus + 500_000_000) / 1_000_000_000))
    }
}
