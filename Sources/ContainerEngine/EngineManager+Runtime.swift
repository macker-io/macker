import Containerization
import ContainerizationOCI
import ContainerizationOS
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
        let image = try await resolveContainerImage(record)
        try await retainImage(image)
        var manager = try await ensureManager()
        await reclaimContainerRuntime(record.id)
        for mount in record.mounts where mount.type == "tmpfs" {
            try FileManager.default.createDirectory(atPath: mount.source, withIntermediateDirectories: true)
        }

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
            let rootfs = try await prepareRootfs(id: record.id, image: image)
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
                config.useInit = prepared.run.initProcess
                if !prepared.run.sysctls.isEmpty {
                    config.sysctl = prepared.run.sysctls
                }
                if prepared.run.privileged {
                    config.process.capabilities = .allCapabilities
                    config.maskedPaths = []
                    config.readonlyPaths = []
                }
                Self.applyCapabilities(
                    &config.process.capabilities,
                    add: prepared.run.capAdd,
                    drop: prepared.run.capDrop
                )
                if prepared.run.securityOpt.contains(where: { opt in
                    opt == "no-new-privileges" || opt == "no-new-privileges:true" || opt == "no-new-privileges=true"
                }) {
                    config.process.noNewPrivileges = true
                }
                if !prepared.run.ulimits.isEmpty {
                    config.process.rlimits = Self.rlimits(prepared.run.ulimits)
                }
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
            snapshotBaseline(record.id)
            try await created.create()
            try await created.start()
        } catch {
            try? await linux?.stop()
            vms[record.id] = nil
            await reclaimContainerRuntime(record.id)
            throw EngineError.runtimeUnavailable("failed to start MicroVM: \(error.localizedDescription)")
        }

        guard let linux else {
            await reclaimContainerRuntime(record.id)
            throw EngineError.runtimeUnavailable("failed to start MicroVM")
        }
        vms[record.id] = linux
        if let stdinPipe {
            containerStdin[record.id] = stdinPipe
        }
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
            guard !Task.isCancelled else { return }
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
        guard !data.isEmpty else { return }
        let tty = containers[id]?.tty == true
        let attachData: Data
        let logData: Data
        if tty {
            var session = ttySessions[id] ?? TTYSession()
            let output = session.ingest(data)
            ttySessions[id] = session
            attachData = output.attach
            logData = Data(output.log.utf8)
        } else {
            attachData = data
            logData = data
        }
        let timestamp = Date()
        if !logData.isEmpty, containers[id] != nil {
            appendLogRecord(id: id, chunk: EngineIOChunk(data: logData, stdout: stdout, timestamp: timestamp))
        }
        guard let subscribers = attachSubscribers[id] else { return }
        for subscriber in subscribers.values {
            let payload: Data
            if subscriber.kind == .logs, tty {
                payload = logData
            } else {
                payload = attachData
            }
            guard !payload.isEmpty else { continue }
            subscriber.continuation.yield(EngineIOChunk(data: payload, stdout: stdout, timestamp: timestamp))
        }
    }

    func reclaimContainerRuntime(_ id: String) async {
        await stopPortPublishers(id)
        await releaseInterfaces(id)
        Self.removeTransientContainerFiles(id, root: containerRoot)
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

    static func applyCapabilities(_ caps: inout Containerization.LinuxCapabilities, add: [String], drop: [String]) {
        func parse(_ raw: String) -> [CapabilityName] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmed == "ALL" || trimmed == "CAP_ALL" {
                return CapabilityName.allCases
            }
            let normalized = trimmed.hasPrefix("CAP_") ? trimmed : "CAP_\(trimmed)"
            if let cap = try? CapabilityName(rawValue: normalized) {
                return [cap]
            }
            return []
        }

        for item in drop {
            let removed = Set(parse(item))
            guard !removed.isEmpty else { continue }
            caps.bounding.removeAll { removed.contains($0) }
            caps.effective.removeAll { removed.contains($0) }
            caps.inheritable.removeAll { removed.contains($0) }
            caps.permitted.removeAll { removed.contains($0) }
            caps.ambient.removeAll { removed.contains($0) }
        }
        for item in add {
            for cap in parse(item) {
                if !caps.bounding.contains(cap) { caps.bounding.append(cap) }
                if !caps.effective.contains(cap) { caps.effective.append(cap) }
                if !caps.permitted.contains(cap) { caps.permitted.append(cap) }
            }
        }
    }

    static func rlimits(_ items: [EngineUlimit]) -> [LinuxRLimit] {
        let map: [String: String] = [
            "as": "RLIMIT_AS",
            "core": "RLIMIT_CORE",
            "cpu": "RLIMIT_CPU",
            "data": "RLIMIT_DATA",
            "fsize": "RLIMIT_FSIZE",
            "locks": "RLIMIT_LOCKS",
            "memlock": "RLIMIT_MEMLOCK",
            "msgqueue": "RLIMIT_MSGQUEUE",
            "nice": "RLIMIT_NICE",
            "nofile": "RLIMIT_NOFILE",
            "nproc": "RLIMIT_NPROC",
            "rss": "RLIMIT_RSS",
            "rtprio": "RLIMIT_RTPRIO",
            "rttime": "RLIMIT_RTTIME",
            "sigpending": "RLIMIT_SIGPENDING",
            "stack": "RLIMIT_STACK",
        ]
        return items.compactMap { item in
            let lower = item.name.lowercased()
            let key = map[lower] ?? (lower.hasPrefix("rlimit_") ? item.name.uppercased() : "RLIMIT_\(item.name.uppercased())")
            guard let kind = try? LinuxRLimit.Kind(key) else { return nil }
            return LinuxRLimit(kind: kind, hard: item.hard, soft: item.soft)
        }
    }
}
