import Containerization
import Foundation

extension EngineManager {
    public func listContainers(all: Bool = true, filters: [String: [String]] = [:]) -> [EngineContainerSummary] {
        var items = containers.values.filter { all || $0.isActive }.map(\.summary)
        if let names = filters["name"], !names.isEmpty {
            items = items.filter { item in names.contains { needle in item.names.contains { $0.contains(needle) } } }
        }
        if let ids = filters["id"], !ids.isEmpty {
            items = items.filter { item in ids.contains { item.id.hasPrefix($0) || item.id == $0 } }
        }
        if let statuses = filters["status"], !statuses.isEmpty {
            items = items.filter { statuses.contains($0.state) }
        }
        if let ancestors = filters["ancestor"], !ancestors.isEmpty {
            items = items.filter { item in
                ancestors.contains { item.image.contains($0) || item.imageID.contains($0) }
            }
        }
        if let labels = filters["label"], !labels.isEmpty {
            items = items.filter { FilterMatch.labels($0.labels, specs: labels) }
        }
        return items.sorted { $0.created > $1.created }
    }

    public func createContainer(_ spec: EngineContainerCreateSpec) async throws -> EngineContainerCreateResult {
        let image = try await inspectImage(name: spec.image)
        let name = try uniqueName(spec.name)
        let id = Self.makeContainerID()
        let command = (spec.entrypoint ?? image.entrypoint) + (spec.cmd ?? image.cmd)
        let env = image.env + spec.env
        let now = Date()
        let mounts = try await resolveMounts(spec.volumeRequests)
        let attached = try attachCreateEndpoints(spec)
        let portBindings = attached.mode == "host" || attached.mode == "none" ? [] : spec.portBindings
        let exposedPorts = EnginePortBinding.merging(image.exposedPorts, spec.exposedPorts)
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
            exposedPorts: exposedPorts
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

    public func inspectContainer(_ idOrName: String) async throws -> EngineContainer {
        try resolveContainer(idOrName)
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
        await publish(EngineEvent(type: "container", action: "start", actorID: container.id, attributes: ["name": container.name, "image": container.image]))
        return true
    }

    public func stopContainer(_ idOrName: String, timeoutSeconds: Int = 10) async throws -> Bool {
        let container = try resolveContainer(idOrName)
        if container.state == "exited" || container.state == "created" {
            return false
        }
        await stopVM(container.id, timeoutSeconds: timeoutSeconds)
        await handleVMExit(id: container.id, code: 143, action: "stop")
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

    public func waitContainer(_ idOrName: String) async throws -> Int {
        let container = try resolveContainer(idOrName)
        if container.state == "exited" || container.state == "dead" {
            return container.exitCode
        }
        return await withCheckedContinuation { continuation in
            waiters[container.id, default: []].append(continuation)
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

    public func pruneContainers() async -> (deleted: [String], spaceReclaimed: Int64) {
        let stopped = containers.values.filter { $0.state == "exited" || $0.state == "created" || $0.state == "dead" }
        var deleted: [String] = []
        for container in stopped {
            finishAttachSubscribers(container.id, extra: nil)
            await finishExecs(forContainer: container.id, code: 0)
            for (id, exec) in execs where exec.containerID == container.id {
                execs[id] = nil
            }
            await forgetContainer(container.id)
            deleted.append(container.id)
            await publish(EngineEvent(type: "container", action: "destroy", actorID: container.id, attributes: ["name": container.name]))
        }
        return (deleted, 0)
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

    public func updateContainer(_ idOrName: String, memory: Int64?, nanoCpus: Int64?) async throws {
        var container = try resolveContainer(idOrName)
        if let memory {
            container.memory = memory
        }
        if let nanoCpus {
            container.nanoCpus = nanoCpus
        }
        saveContainer(container)
        await publish(EngineEvent(type: "container", action: "update", actorID: container.id, attributes: ["name": container.name]))
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
        container.state = "exited"
        container.exitCode = exitCode
        container.finishedAt = Date()
        let id = container.id
        if container.autoRemove {
            await forgetContainer(id)
        } else {
            saveContainer(container)
        }
        finishWaiters(id: id, code: exitCode)
        finishAttachSubscribers(id, extra: "container \(String(id.prefix(12))) \(action)\n")
        await finishExecs(forContainer: id, code: exitCode)
        await publish(EngineEvent(type: "container", action: action, actorID: id, attributes: ["name": container.name]))
    }

    private func finishWaiters(id: String, code: Int) {
        let pending = waiters.removeValue(forKey: id) ?? []
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
            _ = try? await stopContainer(id, timeoutSeconds: 10)
        }
        await networkGateway.shutdown()
    }

    func saveContainer(_ container: EngineContainer) {
        containers[container.id] = container
        try? persistContainer(container)
    }

    func forgetContainer(_ id: String) async {
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

    static func restoreContainers(_ containers: inout [String: EngineContainer], root: URL) {
        let now = Date()
        var removed: [String] = []
        for (id, var container) in containers {
            guard container.isActive else { continue }
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
        for id in removed {
            containers[id] = nil
            removeContainerFiles(id, root: root)
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
}
