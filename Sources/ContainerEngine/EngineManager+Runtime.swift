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
        await reclaimContainerRuntime(record.id)
        // tmpfs mounts live in the runtime directory just reset: recreate them empty.
        for mount in record.mounts where mount.type == "tmpfs" && !mount.source.isEmpty {
            try FileManager.default.createDirectory(atPath: mount.source, withIntermediateDirectories: true)
        }

        let stdoutSink = ProcessLogSink(hopping: { [id = record.id] data in
            await self.appendOutput(id: id, data: data, stdout: true)
        })
        let stderrSink = ProcessLogSink(hopping: { [id = record.id] data in
            await self.appendOutput(id: id, data: data, stdout: false)
        })
        // An attached client may already have written (or closed) stdin before `start`.
        let stdinPipe = (record.openStdin || record.tty) ? (containerStdin[record.id] ?? ProcessStdin()) : nil
        containerStdin[record.id] = stdinPipe
        outputSinks[record.id] = [stdoutSink, stderrSink]

        var prepared = record
        let interfaces: [any Interface]
        do {
            interfaces = try await allocateInterfaces(for: &prepared)
            saveContainer(prepared)
            await networkGateway.setDNS(containerID: prepared.id, nameservers: prepared.run.dns)
        } catch {
            await releaseInterfaces(record.id)
            throw error
        }
        let dns = dnsConfig(for: prepared)
        let hosts = hostsFile(for: prepared)

        var linux: LinuxContainer?
        do {
            // Attach virtio-net ourselves. ContainerManager's single `network:` cannot
            // express none / host / multiple networks.
            var rootfs = try await prepareRootfs(id: record.id, image: image)
            if prepared.run.readonlyRootfs {
                rootfs.options.append("ro")
            }
            let created = try await manager.create(
                record.id,
                image: image,
                rootfs: rootfs,
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
                config.process.capabilities = .init(capabilities: Self.containerCapabilities(prepared))
                if prepared.run.privileged {
                    // Privileged inside the guest kernel only: nothing is masked or read-only.
                    config.maskedPaths = []
                    config.readonlyPaths = []
                }
                config.useInit = prepared.run.useInit == true
                if let stdinPipe {
                    config.process.stdin = stdinPipe
                }
                config.process.stdout = stdoutSink
                if !prepared.tty {
                    config.process.stderr = stderrSink
                }
                config.hostname = prepared.hostname
                // An explicit limit sizes the whole MicroVM, so the guest's nproc and
                // MemTotal match what was asked for (no hidden agent headroom).
                config.cpus = Self.cpuCount(nanoCpus: prepared.nanoCpus)
                if prepared.nanoCpus > 0 {
                    config.cpuOverhead = 0
                }
                config.memoryInBytes = prepared.memory > 0 ? UInt64(prepared.memory) : Self.defaultMemoryBytes
                if prepared.memory > 0 {
                    config.memoryOverhead = 0
                }
                for mount in prepared.mounts where !mount.source.isEmpty && !mount.destination.isEmpty {
                    var options: [String] = []
                    if !mount.rw {
                        options.append("ro")
                    }
                    if mount.type == EngineMount.blockType {
                        // A Linux filesystem image attached as a disk (overlay-capable,
                        // unlike virtiofs); only one running VM may use it at a time.
                        config.mounts.append(.block(format: "ext4", source: mount.source, destination: mount.destination, options: options))
                        continue
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
            snapshotBaseline(record.id)
            try await created.create()
            try await applyPendingArchives(record.id, to: created)
            try await created.start()
        } catch {
            try? await linux?.stop()
            vms[record.id] = nil
            await drainOutput(record.id)
            containerStdin[record.id] = nil
            await reclaimContainerRuntime(record.id)
            if error.localizedDescription.contains("failed to find target executable") {
                // Docker's wording; clients map "executable file not found" to exit 127.
                throw EngineError.runtimeUnavailable(
                    "failed to create task for container: " + Self.describeExecFailure(error, command: prepared.command)
                )
            }
            throw EngineError.runtimeUnavailable("failed to start MicroVM: \(error.localizedDescription)")
        }

        guard let linux else {
            await reclaimContainerRuntime(record.id)
            throw EngineError.runtimeUnavailable("failed to start MicroVM")
        }
        vms[record.id] = linux
        recordGuestNics(prepared)
        do {
            try await applySecondaryBridgeAddresses(containers[record.id] ?? prepared)
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

    /// Sends `signal`, escalates to SIGKILL after `timeoutSeconds`, tears the VM down, and
    /// returns the process exit code (128+n for a signal death; 137 if it never reported).
    @discardableResult
    func stopVM(_ id: String, timeoutSeconds: Int, signal: Signal = .term) async -> Int {
        guard let linux = vms[id] else { return 128 + Int(signal.rawValue) }
        waitTasks[id]?.cancel()
        waitTasks[id] = nil
        var code = 137
        try? await linux.kill(signal)
        do {
            code = Int(try await linux.wait(timeoutInSeconds: Int64(max(timeoutSeconds, 1))).exitCode)
        } catch {
            try? await linux.kill(.kill)
            if let status = try? await linux.wait(timeoutInSeconds: 2) {
                code = Int(status.exitCode)
            }
        }
        await teardownVM(id)
        return code
    }

    /// Waits until every byte the guest wrote has reached logs and subscribers, then
    /// flushes partial lines. Runs before an exit is published.
    func drainOutput(_ id: String) async {
        for sink in outputSinks.removeValue(forKey: id) ?? [] {
            await sink.drain()
        }
        if var session = ttySessions[id] {
            let rest = session.finish()
            ttySessions[id] = session
            if !rest.isEmpty {
                pendingLogLines[id, default: [:]][true, default: ""] += rest
            }
        }
        flushLogLines(id)
    }

    func teardownVM(_ id: String) async {
        await drainOutput(id)
        waitTasks[id]?.cancel()
        waitTasks[id] = nil
        containerStdin[id]?.finish()
        containerStdin[id] = nil
        ttySessions[id] = nil
        statsSamples[id] = nil
        lastStats[id] = nil
        await stopPortPublishers(id)
        if let linux = vms.removeValue(forKey: id) {
            try? await linux.stop()
        }
        await releaseInterfaces(id)
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
        guard !data.isEmpty, containers[id] != nil else { return }
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
        var entries: [EngineLogEntry] = []
        if !logText.isEmpty {
            let now = Date()
            var pending = pendingLogLines[id]?[stdout] ?? ""
            entries = ContainerLogFile.splitLines(logText, pending: &pending).map {
                EngineLogEntry(time: now, stdout: stdout, text: $0)
            }
            pendingLogLines[id, default: [:]][stdout] = pending
        }
        recordLogEntries(id, entries)
        guard !attachData.isEmpty, let subscribers = attachSubscribers[id] else { return }
        for subscriber in subscribers.values where subscriber.kind == .attach {
            subscriber.continuation.yield(EngineIOChunk(data: attachData, stdout: stdout))
        }
    }

    /// Emits partial lines still waiting for a newline (at exit).
    func flushLogLines(_ id: String) {
        guard let pending = pendingLogLines.removeValue(forKey: id) else { return }
        let now = Date()
        let entries = [true, false].compactMap { stdout -> EngineLogEntry? in
            guard let text = pending[stdout], !text.isEmpty else { return nil }
            return EngineLogEntry(time: now, stdout: stdout, text: text)
        }
        recordLogEntries(id, entries)
    }

    /// Stores complete log lines and fans them out to `logs -f` subscribers.
    private func recordLogEntries(_ id: String, _ entries: [EngineLogEntry]) {
        guard !entries.isEmpty, var record = containers[id] else { return }
        record.logs += entries
        containers[id] = record
        appendLogFile(id: id, entries: entries)
        for subscriber in (attachSubscribers[id] ?? [:]).values where subscriber.kind == .logs {
            for entry in entries {
                subscriber.continuation.yield(EngineIOChunk(data: Data(entry.text.utf8), stdout: entry.stdout, time: entry.time))
            }
        }
    }

    func reclaimContainerRuntime(_ id: String) async {
        await stopPortPublishers(id)
        await releaseInterfaces(id)
        resetContainerFiles(id)
    }

    /// Clears per-boot state (tmpfs backing dirs, sockets) but keeps the container's writable
    /// root filesystem, so files survive stop/start like Docker's container layer.
    func resetContainerFiles(_ id: String) {
        Self.resetTransientFiles(id, root: containerRoot)
    }

    /// Runtime-directory entries that belong to the container, not to one boot.
    static let persistentRuntimeFiles: Set<String> = ["rootfs.ext4", "baseline.json", pendingArchivesDirectory]

    static func resetTransientFiles(_ id: String, root: URL) {
        let dir = runtimeURL(id: id, root: root)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items where !persistentRuntimeFiles.contains(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
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
