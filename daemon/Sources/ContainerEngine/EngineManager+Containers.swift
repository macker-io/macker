import Containerization
import Foundation

extension EngineManager {
    public func listContainers(all: Bool = true, filters: [String: [String]] = [:]) -> [EngineContainerSummary] {
        var items = containers.values.map(\.summary)
        if !all {
            items = items.filter { $0.state == "running" || $0.state == "paused" }
        }
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
            status: "Created",
            created: now,
            startedAt: nil,
            finishedAt: nil,
            exitCode: 0,
            logs: "",
            autoRemove: spec.autoRemove,
            memory: spec.memory,
            nanoCpus: spec.nanoCpus,
            networkMode: spec.networkMode,
            tty: spec.tty,
            openStdin: spec.openStdin,
            mounts: mounts
        )
        containers[id] = record
        await publish(EngineEvent(type: "container", action: "create", actorID: id, attributes: ["name": name, "image": spec.image]))
        var warnings: [String] = []
        if spec.networkMode != "none" {
            warnings.append("container network is not attached; the MicroVM has no NIC yet")
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
        container.status = "Up"
        container.startedAt = Date()
        container.finishedAt = nil
        container.exitCode = 0
        containers[container.id] = container
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
        if (try? resolveContainer(idOrName).state) == "running" || (try? resolveContainer(idOrName).state) == "paused" {
            _ = try await stopContainer(idOrName, timeoutSeconds: timeoutSeconds)
        }
        _ = try await startContainer(idOrName)
        let container = try resolveContainer(idOrName)
        await publish(EngineEvent(type: "container", action: "restart", actorID: container.id, attributes: ["name": container.name]))
    }

    public func killContainer(_ idOrName: String, signal: String) async throws {
        let container = try resolveContainer(idOrName)
        guard container.state == "running" || container.state == "paused" else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        let parsed = (try? Signal(signal)) ?? .term
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
        container.status = "Paused"
        containers[container.id] = container
        await publish(EngineEvent(type: "container", action: "pause", actorID: container.id, attributes: ["name": container.name]))
    }

    public func unpauseContainer(_ idOrName: String) async throws {
        var container = try resolveContainer(idOrName)
        guard container.state == "paused" else {
            throw EngineError.conflict("container \(container.id) is not paused")
        }
        try await resumeVM(container.id)
        container.state = "running"
        container.status = "Up"
        containers[container.id] = container
        await publish(EngineEvent(type: "container", action: "unpause", actorID: container.id, attributes: ["name": container.name]))
    }

    public func renameContainer(_ idOrName: String, to newName: String) async throws {
        var container = try resolveContainer(idOrName)
        let name = try uniqueName(newName)
        let old = container.name
        container.name = name
        containers[container.id] = container
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
        _ = removeAnonymousVolumes
        let container = try resolveContainer(idOrName)
        if container.state == "running" || container.state == "paused" {
            guard force else {
                throw EngineError.conflict("cannot remove running container \(container.id): stop or use force")
            }
            await stopVM(container.id, timeoutSeconds: 1, signal: .kill)
            await handleVMExit(id: container.id, code: 137, action: "kill")
        }
        let remaining = try? resolveContainer(container.id)
        let anonymous = (remaining ?? container).mounts.filter(\.anonymous).map(\.name)
        await teardownVM(container.id)
        resetContainerFiles(container.id)
        containers[container.id] = nil
        finishWaiters(id: container.id, code: container.exitCode)
        finishAttachSubscribers(container.id, extra: nil)
        await finishExecs(forContainer: container.id, code: container.exitCode)
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
            resetContainerFiles(container.id)
            containers[container.id] = nil
            finishAttachSubscribers(container.id, extra: nil)
            await finishExecs(forContainer: container.id, code: 0)
            for (id, exec) in execs where exec.containerID == container.id {
                execs[id] = nil
            }
            deleted.append(container.id)
            await publish(EngineEvent(type: "container", action: "destroy", actorID: container.id, attributes: ["name": container.name]))
        }
        return (deleted, 0)
    }

    public func containerLogs(_ idOrName: String) async throws -> (text: String, tty: Bool) {
        let container = try resolveContainer(idOrName)
        return (container.logs, container.tty)
    }

    public func updateContainer(_ idOrName: String, memory: Int64?, nanoCpus: Int64?) async throws {
        var container = try resolveContainer(idOrName)
        if let memory {
            container.memory = memory
        }
        if let nanoCpus {
            container.nanoCpus = nanoCpus
        }
        containers[container.id] = container
        await publish(EngineEvent(type: "container", action: "update", actorID: container.id, attributes: ["name": container.name]))
    }

    public func containerTop(_ idOrName: String) async throws -> EngineContainerTop {
        let container = try resolveContainer(idOrName)
        guard container.state == "running" || container.state == "paused" else {
            throw EngineError.conflict("container \(container.id) is not running")
        }
        let cmd = container.command.joined(separator: " ")
        return EngineContainerTop(
            titles: ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"],
            processes: [["root", "1", "0", "0", "00:00", "?", "00:00:00", cmd]]
        )
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

    func finish(container: inout EngineContainer, exitCode: Int, action: String, status: String) async throws {
        container.state = "exited"
        container.status = status
        container.exitCode = exitCode
        container.finishedAt = Date()
        let id = container.id
        if container.autoRemove {
            containers[id] = nil
        } else {
            containers[id] = container
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
}
