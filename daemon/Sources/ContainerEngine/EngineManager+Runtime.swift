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
        reclaimContainerRuntime(record.id)

        let stdoutSink = ProcessLogSink(hopping: { [id = record.id] data in
            await self.appendOutput(id: id, data: data, stdout: true)
        })
        let stderrSink = ProcessLogSink(hopping: { [id = record.id] data in
            await self.appendOutput(id: id, data: data, stdout: false)
        })
        let stdinPipe = (record.openStdin || record.tty) ? ProcessStdin() : nil

        var prepared = record
        let interfaces: [any Interface]
        do {
            interfaces = try allocateInterfaces(for: &prepared)
            saveContainer(prepared)
        } catch {
            releaseInterfaces(record.id)
            throw error
        }
        let dns = dnsConfig(for: prepared)
        let hosts = hostsFile(for: prepared)

        var linux: LinuxContainer?
        do {
            // Attach virtio-net ourselves. ContainerManager's single `network:` cannot
            // express none / host / multiple networks.
            let created = try await manager.create(
                record.id,
                image: image,
                rootfsSizeInBytes: Self.defaultRootfsBytes,
                networking: false
            ) { config in
                if !prepared.command.isEmpty {
                    config.process.arguments = prepared.command
                }
                let env = Self.mergedEnvironment(prepared.env, tty: prepared.tty)
                if !env.isEmpty {
                    config.process.environmentVariables = env
                }
                if !prepared.workingDir.isEmpty {
                    config.process.workingDirectory = prepared.workingDir
                }
                if !prepared.user.isEmpty {
                    config.process.user = .init(username: prepared.user)
                }
                config.process.terminal = prepared.tty
                if let stdinPipe {
                    config.process.stdin = stdinPipe
                }
                config.process.stdout = stdoutSink
                if !prepared.tty {
                    config.process.stderr = stderrSink
                }
                config.hostname = prepared.hostname
                config.cpus = Self.cpuCount(nanoCpus: prepared.nanoCpus)
                config.memoryInBytes = prepared.memory > 0 ? UInt64(prepared.memory) : Self.defaultMemoryBytes
                for mount in prepared.mounts where !mount.source.isEmpty && !mount.destination.isEmpty {
                    var options: [String] = []
                    if !mount.rw {
                        options.append("ro")
                    }
                    config.mounts.append(.share(source: mount.source, destination: mount.destination, options: options))
                }
                if !interfaces.isEmpty {
                    config.interfaces = interfaces
                    config.dns = dns
                    config.hosts = hosts
                }
            }
            linux = created
            containerManager = manager
            try await created.create()
            try await created.start()
        } catch {
            try? await linux?.stop()
            vms[record.id] = nil
            reclaimContainerRuntime(record.id)
            throw EngineError.runtimeUnavailable("failed to start MicroVM: \(error.localizedDescription)")
        }

        guard let linux else {
            reclaimContainerRuntime(record.id)
            throw EngineError.runtimeUnavailable("failed to start MicroVM")
        }
        vms[record.id] = linux
        if let stdinPipe {
            containerStdin[record.id] = stdinPipe
        }
        do {
            try await startPortPublishers(containers[record.id] ?? prepared)
        } catch {
            await teardownVM(record.id)
            throw error
        }
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
        containerStdin[id]?.finish()
        containerStdin[id] = nil
        ttySessions[id] = nil
        statsSamples[id] = nil
        lastStats[id] = nil
        stopPortPublishers(id)
        if let linux = vms.removeValue(forKey: id) {
            try? await linux.stop()
        }
        releaseInterfaces(id)
    }

    func handleVMExit(id: String, code: Int, action: String) async {
        await teardownVM(id)
        guard var record = containers[id], record.isActive else { return }
        await finish(container: &record, exitCode: code, action: action)
    }

    func appendOutput(id: String, text: String) {
        appendOutput(id: id, data: Data(text.utf8), stdout: true)
    }

    func appendOutput(id: String, data: Data, stdout: Bool) {
        guard !data.isEmpty else { return }
        let tty = containers[id]?.tty == true
        let attachData: Data
        let logText: String
        if tty {
            var session = ttySessions[id] ?? TTYSession()
            let output = session.ingest(data)
            ttySessions[id] = session
            attachData = output.attach
            logText = output.log
        } else {
            attachData = data
            logText = String(decoding: data, as: UTF8.self)
        }
        if !logText.isEmpty, var record = containers[id] {
            record.logs += logText
            containers[id] = record
            appendLogFile(id: id, text: logText)
        }
        guard let subscribers = attachSubscribers[id] else { return }
        for subscriber in subscribers.values {
            let payload: Data
            if subscriber.kind == .logs, tty {
                payload = Data(logText.utf8)
            } else {
                payload = attachData
            }
            guard !payload.isEmpty else { continue }
            subscriber.continuation.yield(EngineIOChunk(data: payload, stdout: stdout))
        }
    }

    func reclaimContainerRuntime(_ id: String) {
        stopPortPublishers(id)
        releaseInterfaces(id)
        resetContainerFiles(id)
    }

    func resetContainerFiles(_ id: String) {
        Self.removeRuntimeDirectory(id, root: containerRoot)
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
        // NICs are attached per container in `bootContainer` (`networking: false`).
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
