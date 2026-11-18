import Containerization
import Foundation

extension EngineManager {
    public func listContainers(
        all: Bool = true,
        size: Bool = false,
        filters: [String: [String]] = [:]
    ) throws -> [EngineContainerSummary] {
        var records = Array(containers.values.filter { all || $0.isActive })
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
        let image = try await inspectImage(name: spec.image)
        let name = try uniqueName(spec.name)
        let id = Self.makeContainerID()
        let command = (spec.entrypoint ?? image.entrypoint) + (spec.cmd ?? image.cmd)
        let env = image.env + spec.env
        let now = Date()
        let tmpfsRoot = Self.runtimeURL(id: id, root: containerRoot).appendingPathComponent("tmpfs", isDirectory: true)
        let fromVolumes = try volumesFrom(spec.volumesFrom)
        let mounts = try await resolveMounts(spec.volumeRequests + fromVolumes, tmpfsRoot: tmpfsRoot)
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
        let record = EngineContainer(
            id: id,
            name: name,
            image: spec.image,
            imageID: image.id,
            command: command,
            env: env,
            workingDir: spec.workingDir.isEmpty ? image.workingDir : spec.workingDir,
            user: spec.user.isEmpty ? image.user : spec.user,
            hostname: spec.hostname.isEmpty ? String(id.prefix(12)) : spec.hostname,
            labels: spec.labels,
            state: "created",
            created: now,
            startedAt: nil,
            finishedAt: nil,
            exitCode: 0,
            logs: "",
            autoRemove: spec.autoRemove,
            memory: spec.memory,
            nanoCpus: spec.nanoCpus,
            networkMode: attached.mode,
            tty: spec.tty,
            openStdin: spec.openStdin,
            mounts: mounts,
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
                healthcheck: EngineHealthcheck.inherit(spec.healthcheck, image: image.healthcheck)
            )
        )
        try persistContainer(record)
        containers[id] = record
        await publish(EngineEvent(type: "container", action: "create", actorID: id, attributes: ["name": name, "image": spec.image]))
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

    public func startContainer(_ idOrName: String) async throws -> Bool {
        var container = try resolveContainer(idOrName)
        if container.state == "running" {
            return false
        }
        if container.state == "paused" {
            throw EngineError.conflict("cannot start a paused container: \(container.id)")
        }
        try await bootContainer(container)
        container = try resolveContainer(container.id)
        container.state = "running"
        container.startedAt = Date()
        container.finishedAt = nil
        container.exitCode = 0
        saveContainer(container)
        watchVM(container.id)
        startHealthMonitor(container.id)
        await publish(EngineEvent(type: "container", action: "start", actorID: container.id, attributes: ["name": container.name, "image": container.image]))
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
        let code = parsed.rawValue == 9 ? 137 : 128 + Int(parsed.rawValue)
        cancelHealthMonitor(container.id)
        await stopVM(container.id, timeoutSeconds: timeout, signal: parsed)
        await handleVMExit(id: container.id, code: code, action: action)
        return true
    }

    public func restartContainer(_ idOrName: String, timeoutSeconds: Int = 10) async throws {
        if (try? resolveContainer(idOrName))?.isActive == true {
            _ = try await stopContainer(idOrName, timeoutSeconds: timeoutSeconds)
        }
        _ = try await startContainer(idOrName)
        let container = try resolveContainer(idOrName)
        await publish(EngineEvent(type: "container", action: "restart", actorID: container.id, attributes: ["name": container.name]))
    }

    public func killContainer(_ idOrName: String, signal: String) async throws {
        let container = try resolveContainer(idOrName)
        guard container.isActive else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        let parsed = Self.parsedKillSignal(signal)
        let code = parsed.rawValue == 9 ? 137 : 128 + Int(parsed.rawValue)
        await stopVM(container.id, timeoutSeconds: 2, signal: parsed)
        await handleVMExit(id: container.id, code: code, action: "kill")
        await publish(EngineEvent(type: "container", action: "die", actorID: container.id, attributes: ["exitCode": "\(code)"]))
    }

    public func pauseContainer(_ idOrName: String) async throws {
        var container = try resolveContainer(idOrName)
        guard container.state == "running" else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        try await pauseVM(container.id)
        container.state = "paused"
        saveContainer(container)
        await publish(EngineEvent(type: "container", action: "pause", actorID: container.id, attributes: ["name": container.name]))
    }

    public func unpauseContainer(_ idOrName: String) async throws {
        var container = try resolveContainer(idOrName)
        guard container.state == "paused" else {
            throw EngineError.conflict("container \(container.id) is not paused")
        }
        try await resumeVM(container.id)
        container.state = "running"
        saveContainer(container)
        await publish(EngineEvent(type: "container", action: "unpause", actorID: container.id, attributes: ["name": container.name]))
    }

    public func renameContainer(_ idOrName: String, to newName: String) async throws {
        var container = try resolveContainer(idOrName)
        let name = try uniqueName(newName)
        let old = container.name
        container.name = name
        saveContainer(container)
        await publish(EngineEvent(type: "container", action: "rename", actorID: container.id, attributes: ["name": name, "oldName": old]))
    }

    /// Docker `POST /containers/{id}/wait?condition=`. `not-running` returns immediately when the
    /// container is not running. `next-exit` waits for a future exit. `removed` waits for deletion.
    public func waitContainer(_ idOrName: String, condition: String = "not-running") async throws -> Int {
        let parsed = try EngineWaitCondition.parse(condition)
        let container = try resolveContainer(idOrName)
        switch parsed {
        case .notRunning:
            if !container.isActive, container.state != "restarting" {
                return container.exitCode
            }
            return await waitForExit(container.id)
        case .nextExit:
            return await waitForExit(container.id)
        case .removed:
            return await waitForRemoval(container.id)
        }
    }

    private func waitForExit(_ id: String) async -> Int {
        await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    private func waitForRemoval(_ id: String) async -> Int {
        await withCheckedContinuation { continuation in
            removedWaiters[id, default: []].append(continuation)
        }
    }

    public func deleteContainer(_ idOrName: String, force: Bool, removeAnonymousVolumes: Bool) async throws {
        let container = try resolveContainer(idOrName)
        if container.isActive {
            guard force else {
                throw EngineError.conflict("cannot remove running container \(container.id): stop or use force")
            }
            await stopVM(container.id, timeoutSeconds: 1, signal: .kill)
            await handleVMExit(id: container.id, code: 137, action: "kill")
        }
        let remaining = try? resolveContainer(container.id)
        let anonymous = (remaining ?? container).mounts.filter(\.anonymous).map(\.name)
        await teardownVM(container.id)
        finishWaiters(id: container.id, code: container.exitCode)
        finishAttachSubscribers(container.id, extra: nil)
        await finishExecs(forContainer: container.id, code: container.exitCode)
        await forgetContainer(container.id)
        if removeAnonymousVolumes {
            for name in anonymous where !name.isEmpty {
                try? await deleteVolume(name, force: true)
            }
        }
        await publish(EngineEvent(type: "container", action: "destroy", actorID: container.id, attributes: ["name": container.name]))
    }

    public func pruneContainers(filters: [String: [String]] = [:]) async throws -> (deleted: [String], spaceReclaimed: Int64) {
        let unused = try listContainers(all: true, filters: filters).filter {
            $0.state == "exited" || $0.state == "created" || $0.state == "dead"
        }
        var deleted: [String] = []
        var space: Int64 = 0
        for item in unused {
            let id = item.id
            space += containerDiskSize(id)
            finishAttachSubscribers(id, extra: nil)
            await finishExecs(forContainer: id, code: 0)
            for (execID, exec) in execs where exec.containerID == id {
                execs[execID] = nil
            }
            let name = item.names.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? id
            await forgetContainer(id)
            deleted.append(id)
            await publish(EngineEvent(type: "container", action: "destroy", actorID: id, attributes: ["name": name]))
        }
        return (deleted, space)
    }

    public func containerLogs(_ idOrName: String, follow: Bool = false) async throws -> (text: String, tty: Bool, live: EngineIOSession?) {
        let container = try resolveContainer(idOrName)
        let text = container.logs
        let tty = container.tty
        let live: EngineIOSession?
        if follow, container.isActive {
            live = subscribeAttach(
                containerID: container.id,
                tty: tty,
                stdin: false,
                kind: .logs
            )
        } else {
            live = nil
        }
        return (text, tty, live)
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
        var resized = false
        if let memory = update.memory {
            if memory < 0 {
                throw EngineError.invalidArgument("invalid memory limit: \(memory)")
            }
            if memory != container.memory {
                container.memory = memory
                resized = true
            }
        }
        if let nanoCpus = update.nanoCpus {
            if nanoCpus < 0 {
                throw EngineError.invalidArgument("invalid NanoCpus: \(nanoCpus)")
            }
            if nanoCpus != container.nanoCpus {
                container.nanoCpus = nanoCpus
                resized = true
            }
        }
        saveContainer(container)
        await publish(EngineEvent(type: "container", action: "update", actorID: container.id, attributes: ["name": container.name]))
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

    func resolveContainer(_ idOrName: String) throws -> EngineContainer {
        let key = idOrName.hasPrefix("/") ? String(idOrName.dropFirst()) : idOrName
        if let container = containers[key] {
            return container
        }
        if let container = containers.values.first(where: {
            $0.name == key || $0.id.hasPrefix(key)
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
        await publish(EngineEvent(type: "container", action: action, actorID: id, attributes: ["name": container.name]))

        // Graceful daemon exit: keep always/unless-stopped as running on disk so the next
        // boot treats them as interrupted, not as a manual `stop`.
        if action == "shutdown", container.run.restartPolicy.resumesAfterDaemonExit {
            container.state = "running"
            container.finishedAt = nil
            saveContainer(container)
            await teardownSession(id, extra: action, code: exitCode)
            return
        }

        container.state = "exited"
        container.exitCode = exitCode
        container.finishedAt = Date()
        let restart = container.run.restartPolicy.shouldRestart(
            exitCode: exitCode,
            action: action,
            restartCount: container.run.restartCount
        )
        if restart {
            container.run.restartCount += 1
            saveContainer(container)
            await teardownSession(id, extra: action, code: exitCode)
            do {
                _ = try await startContainer(id)
            } catch {
                container.state = "exited"
                saveContainer(container)
            }
            return
        }
        if container.autoRemove {
            await forgetContainer(id)
        } else {
            saveContainer(container)
        }
        await teardownSession(id, extra: action, code: exitCode)
    }

    private func teardownSession(_ id: String, extra action: String, code: Int) async {
        finishAttachSubscribers(id, extra: "container \(String(id.prefix(12))) \(action)\n")
        await finishExecs(forContainer: id, code: code)
        finishWaiters(id: id, code: code)
    }

    private func finishWaiters(id: String, code: Int) {
        let pending = waiters.removeValue(forKey: id) ?? []
        for waiter in pending {
            waiter.resume(returning: code)
        }
    }

    private func finishRemovedWaiters(id: String, code: Int) {
        let pending = removedWaiters.removeValue(forKey: id) ?? []
        for waiter in pending {
            waiter.resume(returning: code)
        }
    }

    private func uniqueName(_ requested: String?) throws -> String {
        let raw = requested?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let name: String
        if raw.isEmpty {
            name = "macker-\(String(Self.makeContainerID().prefix(12)))"
        } else {
            name = raw
        }
        if containers.values.contains(where: { $0.name == name }) {
            throw EngineError.conflict("Conflict. The container name \"/\(name)\" is already in use")
        }
        return name
    }

    public func shutdown() async {
        let ids = containers.values.filter(\.isActive).map(\.id)
        for id in ids {
            _ = try? await stopContainer(id, timeoutSeconds: 10, action: "shutdown")
        }
        await networkGateway.shutdown()
    }

    func saveContainer(_ container: EngineContainer) {
        containers[container.id] = container
        try? persistContainer(container)
    }

    func forgetContainer(_ id: String) async {
        let code = containers[id]?.exitCode ?? 0
        cancelHealthMonitor(id)
        await stopPortPublishers(id)
        await releaseInterfaces(id, keepAddresses: false)
        containers[id] = nil
        finishRemovedWaiters(id: id, code: code)
        finishWaiters(id: id, code: code)
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
                var container = try? decoder.decode(EngineContainer.self, from: data)
            else {
                continue
            }
            let logFile = Self.logURL(id: container.id, root: root)
            let raw = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
            container.logs = container.tty ? TTYSession.cook(raw) : raw
            if container.tty, container.logs != raw {
                try? container.logs.write(to: logFile, atomically: true, encoding: .utf8)
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
                removeRuntimeDirectory(id, root: root)
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
            _ = try? await startContainer(id)
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
        for url in [stateURL(id: id, root: root), logURL(id: id, root: root)] {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
        removeRuntimeDirectory(id, root: root)
    }

    static func removeRuntimeDirectory(_ id: String, root: URL) {
        let path = runtimeURL(id: id, root: root)
        if FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
    }

    func appendLogFile(id: String, text: String) {
        let url = Self.logURL(id: id, root: containerRoot)
        let data = Data(text.utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func stateURL(id: String, root: URL) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    private static func logURL(id: String, root: URL) -> URL {
        root.appendingPathComponent("\(id).log")
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
