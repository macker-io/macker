import Containerization
import Foundation

/// A pending `wait` on one container.
struct EngineWaiter: Sendable {
    let condition: EngineWaitCondition
    let continuation: AsyncStream<Int>.Continuation
}

extension EngineManager {
    public func listContainers(
        all: Bool = true,
        size: Bool = false,
        filters: [String: [String]] = [:]
    ) throws -> [EngineContainerSummary] {
        var records = Array(containers.values.filter { !$0.isSystem && (all || $0.isActive) })
        if let names = filters["name"], !names.isEmpty {
            records = records.filter { item in
                names.contains { needle in item.name.contains(needle) || item.id.contains(needle) }
            }
        }
        if let ids = filters["id"], !ids.isEmpty {
            records = records.filter { item in ids.contains { item.id.hasPrefix($0) || item.id == $0 } }
        }
        if let statuses = filters["status"], !statuses.isEmpty {
            records = records.filter { statuses.contains($0.state) }
        }
        if let health = filters["health"], !health.isEmpty {
            records = records.filter { item in
                let status = item.health?.status ?? "none"
                return health.contains { $0 == status || ($0 == "none" && item.health == nil) }
            }
        }
        if let ancestors = filters["ancestor"], !ancestors.isEmpty {
            records = records.filter { item in
                ancestors.contains { item.image.contains($0) || item.imageID.contains($0) }
            }
        }
        if let labels = filters["label"], !labels.isEmpty {
            records = records.filter { FilterMatch.labels($0.labels, specs: labels) }
        }
        if let excluded = filters["label!"], !excluded.isEmpty {
            records = records.filter { !FilterMatch.labels($0.labels, specs: excluded) }
        }
        if let exited = filters["exited"], !exited.isEmpty {
            records = records.filter { exited.contains(String($0.exitCode)) }
        }
        if let volumes = filters["volume"], !volumes.isEmpty {
            records = records.filter { item in
                volumes.contains { needle in
                    item.mounts.contains { $0.name.contains(needle) || $0.source.contains(needle) || $0.destination.contains(needle) }
                }
            }
        }
        if let networks = filters["network"], !networks.isEmpty {
            records = records.filter { item in
                networks.contains { needle in
                    item.networkMode.contains(needle)
                        || item.endpoints.contains { $0.networkName.contains(needle) || $0.networkID.hasPrefix(needle) }
                }
            }
        }
        if let published = filters["publish"], !published.isEmpty {
            records = records.filter { item in
                published.contains { needle in item.portBindings.contains { Self.portMatches($0, spec: needle, host: true) } }
            }
        }
        if let exposed = filters["expose"], !exposed.isEmpty {
            records = records.filter { item in
                exposed.contains { needle in
                    item.portBindings.contains { Self.portMatches($0, spec: needle, host: false) }
                        || item.exposedPorts.contains { Self.portMatches($0, spec: needle, host: false) }
                }
            }
        }
        if let since = filters["since"]?.first {
            let created = try resolveContainer(since).created
            records = records.filter { $0.created > created }
        }
        if let before = filters["before"]?.first {
            let created = try resolveContainer(before).created
            records = records.filter { $0.created < created }
        }
        if let until = filters["until"]?.compactMap(ISO8601.parseTimestamp), let cutoff = until.min() {
            records = records.filter { $0.created < cutoff }
        }
        var items = records.map(\.summary).sorted { $0.created > $1.created }
        if size {
            for index in items.indices {
                let bytes = containerDiskSize(items[index].id)
                items[index].sizeRw = bytes
                items[index].sizeRootFs = bytes
            }
        }
        return items
    }

    public func createContainer(_ spec: EngineContainerCreateSpec) async throws -> EngineContainerCreateResult {
        try await createContainer(spec, systemMounts: [])
    }

    func createContainer(_ spec: EngineContainerCreateSpec, systemMounts: [EngineMount]) async throws -> EngineContainerCreateResult {
        // Reject invalid host settings before creating mounts, volumes, or network leases.
        try Self.validateResources(memory: spec.memory, nanoCpus: spec.nanoCpus)
        _ = try GuestCapabilities.resolve(privileged: spec.privileged, add: spec.capAdd, drop: spec.capDrop)
        _ = try Self.rlimits(spec.ulimits)
        if let invalid = spec.securityOpt.first(where: { !EngineContainerRunConfig.supportedSecurityOptions.contains($0) }) {
            throw EngineError.invalidArgument("unsupported security option: \(invalid)")
        }
        let source = try await resolveImage(spec.image)
        try await retainImage(source)
        let image = try await inspectImage(name: source.digest)
        let name = try uniqueName(spec.name)
        let id = Self.makeContainerID()
        // Docker CLI sends [""] for an explicit --entrypoint="" reset.
        let entrypoint = spec.entrypoint == [""] ? [] : (spec.entrypoint ?? image.entrypoint)
        // Docker drops the image CMD when the entrypoint is overridden.
        let cmd = spec.cmd ?? (spec.entrypoint == nil ? image.cmd : [])
        let command = entrypoint + cmd
        if command.isEmpty, spec.entrypoint != nil {
            // Do not let the VM layer re-inherit an image command explicitly cleared by the caller.
            throw EngineError.invalidArgument("No command specified")
        }
        let env = image.env + spec.env
        let now = Date()
        let tmpfsRoot = Self.runtimeURL(id: id, root: containerRoot).appendingPathComponent("tmpfs", isDirectory: true)
        let fromVolumes = try volumesFrom(spec.volumesFrom)
        var requests = spec.volumeRequests + fromVolumes
        // System builders supply their own block-backed state, not image-declared shares.
        if !spec.system {
            let occupied = Set(requests.map(\.destination))
            for path in image.volumes where !occupied.contains(path) {
                requests.append(EngineVolumeRequest(type: "volume", source: "", destination: path, anonymous: true))
            }
        }
        let attached = try attachCreateEndpoints(spec)
        let exposedPorts = EnginePortBinding.merging(image.exposedPorts, spec.exposedPorts)
        var portBindings = attached.mode == "host" || attached.mode == "none" ? [] : spec.portBindings
        if spec.publishAllPorts, attached.mode != "host", attached.mode != "none" {
            for port in exposedPorts where !portBindings.contains(where: { $0.dockerKey == port.dockerKey }) {
                portBindings.append(
                    EnginePortBinding(hostIP: "", hostPort: 0, containerPort: port.containerPort, protocolName: port.protocolName)
                )
            }
        }
        if spec.autoRemove, spec.restartPolicy.name != "no" {
            throw EngineError.invalidArgument("Conflicting options: --restart and --rm")
        }
        for extra in spec.extraHosts {
            _ = try EngineExtraHost.parse(extra)
        }
        var record = EngineContainer(
            id: id,
            name: name,
            image: spec.image,
            imageID: image.id,
            command: command,
            env: env,
            workingDir: spec.workingDir.isEmpty ? image.workingDir : spec.workingDir,
            user: spec.user.isEmpty ? image.user : spec.user,
            hostname: spec.hostname.isEmpty ? String(id.prefix(12)) : spec.hostname,
            labels: image.labels.merging(spec.labels) { _, override in override },
            state: "created",
            created: now,
            startedAt: nil,
            finishedAt: nil,
            exitCode: 0,
            autoRemove: spec.autoRemove,
            memory: spec.memory,
            nanoCpus: spec.nanoCpus,
            networkMode: attached.mode,
            tty: spec.tty,
            openStdin: spec.openStdin,
            stdinOnce: spec.stdinOnce,
            mounts: [],
            endpoints: attached.endpoints,
            portBindings: portBindings,
            exposedPorts: exposedPorts,
            run: EngineContainerRunConfig(
                extraHosts: spec.extraHosts,
                dns: spec.dns,
                dnsSearch: spec.dnsSearch,
                dnsOptions: spec.dnsOptions,
                restartPolicy: spec.restartPolicy,
                stopSignal: spec.stopSignal,
                stopTimeout: spec.stopTimeout,
                privileged: spec.privileged,
                readonlyRootfs: spec.readonlyRootfs,
                domainname: spec.domainname,
                groupAdd: spec.groupAdd,
                publishAllPorts: spec.publishAllPorts,
                healthcheck: EngineHealthcheck.inherit(spec.healthcheck, image: image.healthcheck),
                useInit: spec.useInit,
                sysctls: spec.sysctls,
                capAdd: spec.capAdd,
                capDrop: spec.capDrop,
                securityOpt: spec.securityOpt,
                ulimits: spec.ulimits,
                entrypoint: entrypoint,
                cmd: cmd,
                system: spec.system ? true : nil
            )
        )
        var createdAnonymous: [String] = []
        do {
            record.mounts = try await resolveMounts(requests, tmpfsRoot: tmpfsRoot, createdAnonymous: &createdAnonymous) + systemMounts
            // A network may have been removed while volume creation published its events.
            for endpoint in attached.endpoints { _ = try resolveNetwork(endpoint.networkID) }
            try persistContainer(record)
        } catch {
            // A reused anonymous volume is not ours to roll back. deleteVolume also
            // protects a newly-created volume if another container already references it.
            for name in createdAnonymous where volumes[name]?.anonymous == true {
                try? await deleteVolume(name, force: false)
            }
            throw error
        }
        containers[id] = record
        await publish(containerEvent("create", record))
        var warnings = attached.warnings
        if attached.mode == "host", exposedPorts.isEmpty {
            warnings.append("host network: image has no ExposedPorts; Mac localhost will not be proxied")
        }
        return EngineContainerCreateResult(id: id, warnings: warnings)
    }

    public func inspectContainer(_ idOrName: String, size: Bool = false) async throws -> (container: EngineContainer, sizeRw: Int64, sizeRootFs: Int64) {
        let container = try resolveContainer(idOrName)
        guard size else {
            return (container, -1, -1)
        }
        let bytes = containerDiskSize(container.id)
        return (container, bytes, bytes)
    }

    /// User-initiated start. Like Docker, it resets the restart-policy counter.
    public func startContainer(_ idOrName: String) async throws -> Bool {
        try await startContainer(idOrName, byRestartPolicy: false)
    }

    func startContainer(_ idOrName: String, byRestartPolicy: Bool) async throws -> Bool {
        let id = try resolveContainer(idOrName).id
        if let inflight = startTasks[id] {
            // Someone else is booting it: once that boot succeeds the container is running;
            // if it failed, this caller makes its own attempt below.
            if (try? await inflight.task.value) != nil {
                return false
            }
            if let again = startTasks[id] {
                _ = try await again.task.value
                return false
            }
        }
        let token = UUID()
        let task = Task { try await self.bootAndMarkRunning(id, byRestartPolicy: byRestartPolicy) }
        startTasks[id] = (token, task)
        defer {
            if startTasks[id]?.token == token {
                startTasks[id] = nil
            }
        }
        return try await task.value
    }

    private func bootAndMarkRunning(_ id: String, byRestartPolicy: Bool) async throws -> Bool {
        var container = try resolveContainer(id)
        if container.state == "running" {
            return false
        }
        if container.state == "paused" {
            throw EngineError.conflict("cannot start a paused container: \(container.id)")
        }
        if !byRestartPolicy, container.run.restartCount != 0 {
            container.run.restartCount = 0
            saveContainer(container)
        }
        do {
            try await bootContainer(container)
        } catch {
            // Like Docker's start-failure reset: end attached streams so clients that
            // attached before `start` (`docker run`) do not wait forever, and remove
            // an AutoRemove container (`docker run --rm` waits for `removed`).
            finishAttachSubscribers(container.id)
            if container.autoRemove {
                try? await removeContainer(container, force: true, removeAnonymousVolumes: true)
            }
            throw error
        }
        container = try resolveContainer(container.id)
        container.state = "running"
        container.startedAt = Date()
        container.finishedAt = nil
        container.exitCode = 0
        saveContainer(container)
        watchVM(container.id)
        startHealthMonitor(container.id)
        await publish(containerEvent("start", container))
        return true
    }

    public func stopContainer(
        _ idOrName: String,
        timeoutSeconds: Int? = nil,
        signal: String? = nil,
        action: String = "stop"
    ) async throws -> Bool {
        let container = try resolveContainer(idOrName)
        if container.state == "exited" || container.state == "created" {
            return false
        }
        let timeout = timeoutSeconds ?? (container.run.stopTimeout > 0 ? container.run.stopTimeout : 10)
        let rawSignal = signal ?? (container.run.stopSignal.isEmpty ? nil : container.run.stopSignal)
        let parsed = rawSignal.map { Self.parsedKillSignal($0) } ?? .term
        cancelHealthMonitor(container.id)
        if action == "stop" {
            await publish(containerEvent("kill", container, extra: ["signal": "\(parsed.rawValue)"]))
        }
        let code = await stopVM(container.id, timeoutSeconds: timeout, signal: parsed)
        await handleVMExit(id: container.id, code: code, action: action)
        return true
    }

    public func restartContainer(_ idOrName: String, timeoutSeconds: Int = 10) async throws {
        if (try? resolveContainer(idOrName))?.isActive == true {
            _ = try await stopContainer(idOrName, timeoutSeconds: timeoutSeconds)
        }
        _ = try await startContainer(idOrName)
        let container = try resolveContainer(idOrName)
        await publish(containerEvent("restart", container))
    }

    /// Delivers `signal` to the container's main process. Only SIGKILL waits for the exit;
    /// any other signal is just sent, and the process decides (Docker `kill` semantics).
    public func killContainer(_ idOrName: String, signal: String) async throws {
        var container = try resolveContainer(idOrName)
        let parsed = try Self.killSignal(signal)
        guard container.isActive, let linux = vms[container.id] else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        if container.state == "paused" {
            try await resumeVM(container.id)
            container.state = "running"
            saveContainer(container)
        }
        let suppressRestart = Self.killSuppressesRestart(parsed, stopSignal: container.run.stopSignal)
        let marked = suppressRestart && manuallySignaledForExit.insert(container.id).inserted
        // Register before delivery: the guest may exit before kill() returns.
        let exited = parsed == .kill ? waitStream(container.id, condition: .notRunning) : nil
        do {
            try await linux.kill(parsed)
        } catch {
            if marked { manuallySignaledForExit.remove(container.id) }
            throw error
        }
        await publish(containerEvent("kill", container, extra: ["signal": "\(parsed.rawValue)"]))
        if let exited, await Self.first(of: exited, timeoutSeconds: 10) == nil {
            // The guest did not report the exit; tear the VM down ourselves.
            let code = await stopVM(container.id, timeoutSeconds: 1, signal: .kill)
            await handleVMExit(id: container.id, code: code, action: "kill")
        }
    }

    public func pauseContainer(_ idOrName: String) async throws {
        var container = try resolveContainer(idOrName)
        guard container.state == "running" else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        try await pauseVM(container.id)
        container.state = "paused"
        saveContainer(container)
        await publish(containerEvent("pause", container))
    }

    public func unpauseContainer(_ idOrName: String) async throws {
        var container = try resolveContainer(idOrName)
        guard container.state == "paused" else {
            throw EngineError.conflict("container \(container.id) is not paused")
        }
        try await resumeVM(container.id)
        container.state = "running"
        saveContainer(container)
        await publish(containerEvent("unpause", container))
    }

    public func renameContainer(_ idOrName: String, to newName: String) async throws {
        var container = try resolveContainer(idOrName)
        let name = try uniqueName(newName)
        let old = container.name
        container.name = name
        saveContainer(container)
        await publish(containerEvent("rename", container, extra: ["oldName": "/\(old)"]))
    }

    /// Registers a waiter now and returns a stream that yields the exit code once
    /// `condition` is met. Registration is synchronous with the actor, so a `start`
    /// issued after this call returns can never be missed (`next-exit` before `start`).
    public func waitContainer(
        _ idOrName: String,
        condition: EngineWaitCondition
    ) throws -> AsyncStream<Int> {
        let container = try resolveContainer(idOrName)
        return waitStream(container.id, condition: condition)
    }

    /// Blocks until the container is not running; returns its exit code.
    public func waitContainer(_ idOrName: String) async throws -> Int {
        let stream = try waitContainer(idOrName, condition: .notRunning)
        for await code in stream {
            return code
        }
        throw EngineError.containerNotFound("No such container: \(idOrName)")
    }

    func waitStream(_ id: String, condition: EngineWaitCondition) -> AsyncStream<Int> {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        if condition == .notRunning, let container = containers[id], !container.isActive, container.state != "restarting" {
            continuation.yield(container.exitCode)
            continuation.finish()
            return stream
        }
        let token = UUID()
        waiters[id, default: [:]][token] = EngineWaiter(condition: condition, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropWaiter(id, token: token) }
        }
        return stream
    }

    private func dropWaiter(_ id: String, token: UUID) {
        waiters[id]?[token] = nil
        if waiters[id]?.isEmpty == true {
            waiters[id] = nil
        }
    }

    /// First value of `stream`, or `nil` after `timeoutSeconds`.
    static func first(of stream: AsyncStream<Int>, timeoutSeconds: Int) async -> Int? {
        await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                for await value in stream { return value }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public func deleteContainer(_ idOrName: String, force: Bool, removeAnonymousVolumes: Bool) async throws {
        let container = try resolveContainer(idOrName)
        guard startTasks[container.id] == nil else {
            throw EngineError.conflict("container \(container.id) is starting")
        }
        try await removeContainer(container, force: force, removeAnonymousVolumes: removeAnonymousVolumes)
    }

    private func removeContainer(_ container: EngineContainer, force: Bool, removeAnonymousVolumes: Bool) async throws {
        if container.isActive {
            guard force else {
                throw EngineError.conflict("cannot remove running container \(container.id): stop or use force")
            }
            await stopVM(container.id, timeoutSeconds: 1, signal: .kill)
            await handleVMExit(id: container.id, code: 137, action: "kill")
        }
        let remaining = try? resolveContainer(container.id)
        let mounts = (remaining ?? container).mounts
        await teardownVM(container.id)
        let code = (remaining ?? container).exitCode
        finishAttachSubscribers(container.id)
        await finishExecs(forContainer: container.id, code: code)
        await forgetContainer(container.id)
        notifyWaiters(id: container.id, code: code, removed: true)
        if removeAnonymousVolumes {
            await removeAnonymousMounts(mounts)
        }
        await publish(containerEvent("destroy", remaining ?? container))
    }

    /// Deletes anonymous mounts that no other container still references (`deleteVolume` / refCount).
    private func removeAnonymousMounts(_ mounts: [EngineMount]) async {
        for name in mounts.filter(\.anonymous).map(\.name) where !name.isEmpty {
            try? await deleteVolume(name, force: true)
        }
    }

    public func pruneContainers(filters: [String: [String]] = [:]) async throws -> (deleted: [String], spaceReclaimed: Int64) {
        let unused = try listContainers(all: true, filters: filters).filter {
            $0.state == "exited" || $0.state == "created" || $0.state == "dead"
        }
        var deleted: [String] = []
        var space: Int64 = 0
        for item in unused {
            let id = item.id
            guard startTasks[id] == nil else { continue }
            space += containerDiskSize(id)
            let record = containers[id]
            finishAttachSubscribers(id)
            await finishExecs(forContainer: id, code: 0)
            for (execID, exec) in execs where exec.containerID == id {
                execs[execID] = nil
            }
            await forgetContainer(id)
            notifyWaiters(id: id, code: item.exitCode, removed: true)
            deleted.append(id)
            if let record {
                await publish(containerEvent("destroy", record))
            }
        }
        return (deleted, space)
    }

    public func updateContainer(_ idOrName: String, _ update: EngineContainerUpdate) async throws -> [String] {
        var container = try resolveContainer(idOrName)
        if container.state == "dead" || container.state == "removing" {
            throw EngineError.conflict(
                "Cannot update container \(container.id): container is marked for removal and cannot be \"update\""
            )
        }
        if let policy = update.restartPolicy {
            if container.autoRemove, policy.name != "no" {
                throw EngineError.conflict(
                    "Cannot update container \(container.id): Restart policy cannot be updated because AutoRemove is enabled for the container"
                )
            }
            container.run.restartPolicy = policy
        }
        try Self.validateResources(memory: update.memory ?? 0, nanoCpus: update.nanoCpus ?? 0)
        var resized = false
        if let memory = update.memory, memory != container.memory {
            container.memory = memory
            resized = true
        }
        if let nanoCpus = update.nanoCpus, nanoCpus != container.nanoCpus {
            container.nanoCpus = nanoCpus
            resized = true
        }
        saveContainer(container)
        await publish(containerEvent("update", container))
        if resized, container.isActive {
            return ["memory and CPU limits apply on the next start; a running MicroVM is not resized"]
        }
        return []
    }

    public func containerTop(_ idOrName: String, psArgs: String? = nil) async throws -> EngineContainerTop {
        let container = try resolveContainer(idOrName)
        guard container.isActive else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        switch GuestProc.topSource(psArgs) {
        case .guestPS(let command):
            let result = try await runGuest(container.id, command: command)
            guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EngineError.runtimeUnavailable("exec: \"ps\": no process table")
            }
            return GuestProc.parsePS(result.stdout)
        case .proc:
            return try await readGuestProcessTable(container.id)
        }
    }

    public func containerStats(_ idOrName: String) async throws -> EngineContainerStats {
        let container = try resolveContainer(idOrName)
        if container.state == "paused" {
            if let last = lastStats[container.id] {
                return last
            }
            throw EngineError.conflict("cannot retrieve stats from a paused container")
        }
        guard container.state == "running" else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        var snapshot = try await readGuestSnapshot(container.id)
        if statsSamples[container.id] == nil {
            statsSamples[container.id] = (snapshot.busyJiffies, snapshot.totalJiffies)
            try await Task.sleep(for: .milliseconds(200))
            snapshot = try await readGuestSnapshot(container.id)
        }
        let previous = statsSamples[container.id]
        statsSamples[container.id] = (snapshot.busyJiffies, snapshot.totalJiffies)
        let limit = container.memory > 0 ? UInt64(container.memory) : max(snapshot.memoryTotal, 1)
        let stats = EngineContainerStats(
            read: Date(),
            id: container.id,
            name: "/\(container.name)",
            cpuTotal: GuestProc.cpuNanoseconds(jiffies: snapshot.busyJiffies),
            cpuSystem: GuestProc.cpuNanoseconds(jiffies: snapshot.totalJiffies),
            preCPUTotal: GuestProc.cpuNanoseconds(jiffies: previous?.busy ?? 0),
            preCPUSystem: GuestProc.cpuNanoseconds(jiffies: previous?.total ?? 0),
            onlineCPUs: snapshot.onlineCPUs,
            memoryUsage: snapshot.memoryUsage,
            memoryLimit: limit,
            networks: snapshot.networks.mapValues { EngineNetworkIO(rxBytes: $0.rxBytes, txBytes: $0.txBytes) },
            pids: snapshot.pids
        )
        lastStats[container.id] = stats
        return stats
    }

    /// Smallest MicroVM that boots the guest agent plus a small workload. `--memory` sizes the
    /// whole VM, so Docker's own 6MB floor would yield a guest that cannot start.
    static let minimumMemoryBytes: Int64 = 64 * 1024 * 1024

    static func validateResources(memory: Int64, nanoCpus: Int64) throws {
        if memory < 0 || (memory > 0 && memory < minimumMemoryBytes) {
            throw EngineError.invalidArgument("Minimum memory limit allowed is 64MB (each container is a MicroVM)")
        }
        if nanoCpus < 0 {
            throw EngineError.invalidArgument("Range of CPUs is from 0.01 to the number of CPUs available")
        }
    }

    func resolveContainer(_ idOrName: String) throws -> EngineContainer {
        let key = idOrName.hasPrefix("/") ? String(idOrName.dropFirst()) : idOrName
        if let container = containers[key] {
            return container
        }
        if let container = containers.values.first(where: {
            !$0.isSystem && ($0.name == key || $0.id.hasPrefix(key))
        }) {
            return container
        }
        throw EngineError.containerNotFound("No such container: \(idOrName)")
    }

    func requireUnpaused(_ container: EngineContainer, action: String) throws {
        if container.state == "paused" {
            throw EngineError.conflict("cannot \(action) a paused container")
        }
    }

    func finish(container: inout EngineContainer, exitCode: Int, action: String) async {
        cancelHealthMonitor(container.id)
        let id = container.id
        flushLogLines(id)
        let manuallyStopped = manuallySignaledForExit.remove(id) != nil
        await publish(containerEvent("die", container, extra: ["exitCode": "\(exitCode)"]))
        if action == "stop" {
            await publish(containerEvent("stop", container))
        }

        // Graceful daemon exit: keep always/unless-stopped as running on disk so the next
        // boot treats them as interrupted, not as a manual `stop`.
        if action == "shutdown", container.run.restartPolicy.resumesAfterDaemonExit {
            container.state = "running"
            container.finishedAt = nil
            saveContainer(container)
            await teardownSession(id, code: exitCode)
            return
        }

        container.state = "exited"
        container.exitCode = exitCode
        container.finishedAt = Date()
        let restart = !manuallyStopped && container.run.restartPolicy.shouldRestart(
            exitCode: exitCode,
            action: action,
            restartCount: container.run.restartCount
        )
        if restart {
            container.run.restartCount += 1
            saveContainer(container)
            await teardownSession(id, code: exitCode)
            do {
                _ = try await startContainer(id, byRestartPolicy: true)
            } catch {
                container.state = "exited"
                saveContainer(container)
            }
            return
        }
        if container.autoRemove {
            await forgetContainer(id)
            // Match `docker run --rm`: drop now-unreferenced anonymous volumes with the container.
            await removeAnonymousMounts(container.mounts)
        } else {
            saveContainer(container)
        }
        await teardownSession(id, code: exitCode)
        if container.autoRemove {
            notifyWaiters(id: id, code: exitCode, removed: true)
            await publish(containerEvent("destroy", container))
        }
    }

    private func teardownSession(_ id: String, code: Int) async {
        finishAttachSubscribers(id)
        await finishExecs(forContainer: id, code: code)
        notifyWaiters(id: id, code: code, removed: false)
    }

    /// Resolves exit waiters (`not-running`, `next-exit`); on removal, every waiter.
    func notifyWaiters(id: String, code: Int, removed: Bool) {
        guard var pending = waiters[id] else { return }
        for (token, waiter) in pending where removed || waiter.condition != .removed {
            waiter.continuation.yield(code)
            waiter.continuation.finish()
            pending[token] = nil
        }
        waiters[id] = pending.isEmpty ? nil : pending
    }

    /// Docker event for a container: name, image, and every label as actor attributes.
    func containerEvent(_ action: String, _ container: EngineContainer, extra: [String: String] = [:]) -> EngineEvent {
        var attributes = container.labels
        attributes["name"] = container.name
        attributes["image"] = container.image
        attributes.merge(extra) { _, new in new }
        return EngineEvent(type: "container", action: action, actorID: container.id, attributes: attributes)
    }

    private func uniqueName(_ requested: String?) throws -> String {
        let raw = requested?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let name: String
        if raw.isEmpty {
            name = "macker-\(String(Self.makeContainerID().prefix(12)))"
        } else {
            name = raw
        }
        if containers.values.contains(where: { !$0.isSystem && $0.name == name }) {
            throw EngineError.conflict("Conflict. The container name \"/\(name)\" is already in use")
        }
        return name
    }

    public func shutdown() async {
        // In parallel, like dockerd: each container gets its own stop timeout instead of
        // the daemon's exit taking the sum of all of them.
        let ids = containers.values.filter(\.isActive).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    _ = try? await self.stopContainer(id, action: "shutdown")
                }
            }
        }
        await networkGateway.shutdown()
    }

    func saveContainer(_ container: EngineContainer) {
        containers[container.id] = container
        try? persistContainer(container)
    }

    func forgetContainer(_ id: String) async {
        cancelHealthMonitor(id)
        pendingLogLines[id] = nil
        outputSinks[id] = nil
        manuallySignaledForExit.remove(id)
        await stopPortPublishers(id)
        await releaseInterfaces(id, keepAddresses: false)
        containers[id] = nil
        ttySessions[id] = nil
        statsSamples[id] = nil
        lastStats[id] = nil
        removeContainerFiles(id)
    }

    static func loadContainers(from root: URL) -> [String: EngineContainer] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var loaded: [String: EngineContainer] = [:]
        for file in items where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let container = try? decoder.decode(EngineContainer.self, from: data)
            else {
                continue
            }
            loaded[container.id] = container
        }
        return loaded
    }

    /// Marks leftover running containers as exited (daemon process is gone) and returns the
    /// IDs that `--restart always` / `unless-stopped` should start after boot.
    @discardableResult
    static func restoreContainers(_ containers: inout [String: EngineContainer], root: URL) -> [String] {
        let now = Date()
        var removed: [String] = []
        var restart: [String] = []
        for (id, var container) in containers {
            let wasActive = container.isActive
            if wasActive {
                if container.autoRemove {
                    removed.append(id)
                    continue
                }
                container.state = "exited"
                container.exitCode = 255
                container.finishedAt = now
                containers[id] = container
                try? persistContainer(container, root: root)
                resetTransientFiles(id, root: root)
            }
            let hasStarted = wasActive || container.startedAt != nil
            if container.run.restartPolicy.shouldStartAfterDaemonRestart(wasActive: wasActive, hasStarted: hasStarted) {
                restart.append(id)
            }
        }
        for id in removed {
            containers[id] = nil
            removeContainerFiles(id, root: root)
        }
        return restart.sorted()
    }

    /// Starts containers selected by ``restoreContainers(_:root:)``. Failures leave them exited.
    public func startRestartPolicies() async {
        for id in restartAfterDaemon {
            _ = try? await startContainer(id, byRestartPolicy: true)
        }
    }

    private func persistContainer(_ container: EngineContainer) throws {
        try Self.persistContainer(container, root: containerRoot)
    }

    private static func persistContainer(_ container: EngineContainer, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(container).write(to: stateURL(id: container.id, root: root), options: .atomic)
    }

    private func removeContainerFiles(_ id: String) {
        Self.removeContainerFiles(id, root: containerRoot)
    }

    private static func removeContainerFiles(_ id: String, root: URL) {
        let fm = FileManager.default
        for url in [stateURL(id: id, root: root), logURL(id: id, root: root), logRecordsURL(id: id, root: root)] {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        removeRuntimeDirectory(id, root: root)
    }

    /// Clear only per-boot mounts; keep the writable layer, baseline and pending archives.
    static func resetTransientFiles(_ id: String, root: URL) {
        let runtime = runtimeURL(id: id, root: root)
        try? FileManager.default.removeItem(at: runtime.appendingPathComponent("tmpfs", isDirectory: true))
    }

    private static func removeRuntimeDirectory(_ id: String, root: URL) {
        let path = runtimeURL(id: id, root: root)
        if FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
    }

    private static func stateURL(id: String, root: URL) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    static func runtimeURL(id: String, root: URL) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func containerDiskSize(_ id: String) -> Int64 {
        let rootfs = Self.runtimeURL(id: id, root: containerRoot).appendingPathComponent("rootfs.ext4")
        let values = try? rootfs.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func portMatches(_ binding: EnginePortBinding, spec: String, host: Bool) -> Bool {
        let parts = spec.split(separator: "/", maxSplits: 1)
        let portSpec = String(parts[0])
        let proto = parts.count == 2 ? String(parts[1]).lowercased() : nil
        if let proto, proto != binding.protocolName.lowercased() {
            return false
        }
        let port = host ? binding.hostPort : binding.containerPort
        if let exact = Int(portSpec) {
            return port == exact
        }
        let range = portSpec.split(separator: "-", maxSplits: 1)
        if range.count == 2, let lower = Int(range[0]), let upper = Int(range[1]) {
            return port >= lower && port <= upper
        }
        return false
    }
}
