import ContainerEngine
import Foundation
import NIOCore

extension Router {
    enum NamedContainerRoute: Equatable {
        case inspect(String)
        case top(String)
        case logs(String)
        case stats(String)
        case start(String)
        case stop(String)
        case restart(String)
        case kill(String)
        case update(String)
        case rename(String)
        case pause(String)
        case unpause(String)
        case wait(String)
        case resize(String)
        case delete(String)
        case attach(String)
        case attachWS(String)
        case createExec(String)
        case archive(String)
        case export(String)
        case changes(String)
    }

    private static let reservedContainerNames: Set<String> = ["json", "create", "prune"]

    static func matchNamedContainer(method: String, path: String) -> NamedContainerRoute? {
        guard path.hasPrefix("/containers/") else { return nil }
        let rest = String(path.dropFirst("/containers/".count))
        guard !rest.isEmpty, !reservedContainerNames.contains(rest) else { return nil }

        func decode(_ name: String) -> String {
            name.removingPercentEncoding ?? name
        }

        if rest.hasSuffix("/attach/ws"), method == "GET" {
            return .attachWS(decode(String(rest.dropLast("/attach/ws".count))))
        }

        if let slash = rest.lastIndex(of: "/") {
            let id = decode(String(rest[..<slash]))
            let action = String(rest[rest.index(after: slash)...])
            switch (method, action) {
            case ("GET", "json"):
                return .inspect(id)
            case ("GET", "top"):
                return .top(id)
            case ("GET", "logs"):
                return .logs(id)
            case ("GET", "stats"):
                return .stats(id)
            case ("POST", "start"):
                return .start(id)
            case ("POST", "stop"):
                return .stop(id)
            case ("POST", "restart"):
                return .restart(id)
            case ("POST", "kill"):
                return .kill(id)
            case ("POST", "update"):
                return .update(id)
            case ("POST", "rename"):
                return .rename(id)
            case ("POST", "pause"):
                return .pause(id)
            case ("POST", "unpause"):
                return .unpause(id)
            case ("POST", "wait"):
                return .wait(id)
            case ("POST", "resize"):
                return .resize(id)
            case ("POST", "attach"), ("GET", "attach"):
                return .attach(id)
            case ("POST", "exec"):
                return .createExec(id)
            case ("GET", "archive"), ("HEAD", "archive"), ("PUT", "archive"):
                return .archive(id)
            case ("GET", "export"):
                return .export(id)
            case ("GET", "changes"):
                return .changes(id)
            default:
                return nil
            }
        }

        if method == "DELETE" {
            return .delete(decode(rest))
        }
        return nil
    }

    func handleNamedContainer(_ route: NamedContainerRoute, request: HTTPRequest) async -> HTTPResponse {
        switch route {
        case .inspect(let id):
            return await inspectContainer(id, request: request)
        case .top(let id):
            return await topContainer(id, request: request)
        case .logs(let id):
            return await logsContainer(id, request: request)
        case .stats(let id):
            return await statsContainer(id, request: request)
        case .start(let id):
            return await startContainer(id)
        case .stop(let id):
            return await stopContainer(id, request: request)
        case .restart(let id):
            return await restartContainer(id, request: request)
        case .kill(let id):
            return await killContainer(id, request: request)
        case .update(let id):
            return await updateContainer(id, request: request)
        case .rename(let id):
            return await renameContainer(id, request: request)
        case .pause(let id):
            return await mutateContainer(id) { try await $0.pauseContainer(id) }
        case .unpause(let id):
            return await mutateContainer(id) { try await $0.unpauseContainer(id) }
        case .wait(let id):
            return await waitContainer(id, request: request)
        case .resize(let id):
            return await resizeContainer(id, request: request)
        case .delete(let id):
            return await deleteContainer(id, request: request)
        case .attach(let id):
            return await attachContainer(id, request: request, websocket: false)
        case .attachWS(let id):
            return await attachContainer(id, request: request, websocket: true)
        case .createExec(let id):
            return await createExec(id, request: request)
        case .archive(let id):
            return await archiveContainer(id, request: request)
        case .export(let id):
            return await exportContainer(id)
        case .changes(let id):
            return await containerChanges(id)
        }
    }

    func containersJSON(_ request: HTTPRequest) async -> HTTPResponse {
        let all = Self.queryFlag(request.query["all"])
        let size = Self.queryFlag(request.query["size"])
        let filters = Self.parseFilters(request.query["filters"])
        do {
            var containers = try await engine.listContainers(all: all, size: size, filters: filters).map(DockerContainerSummary.init)
            if let limit = Int(request.query["limit"] ?? ""), limit >= 0 {
                containers = Array(containers.prefix(limit))
            }
            return Self.jsonOK(containers)
        } catch {
            return Self.engineError(error)
        }
    }

    func createContainer(_ request: HTTPRequest) async -> HTTPResponse {
        let spec: EngineContainerCreateSpec
        do {
            let body = try JSONDecoder().decode(DockerCreateContainerRequest.self, from: request.body)
            guard !body.Image.isEmpty else {
                return Self.jsonError(status: 400, message: "Image is required")
            }
            do {
                try DockerCreateValidator.validate(body)
            } catch let rejection as DockerCreateValidator.Rejection {
                return Self.jsonError(status: 400, message: rejection.message)
            }
            // `docker run --platform` sends the platform as a query parameter (API ≥ 1.41).
            try EngineManager.requireRunnablePlatform(request.query["platform"])
            let networkMode = Self.networkMode(body.HostConfig?.NetworkMode)
            spec = EngineContainerCreateSpec(
                name: request.query["name"],
                image: body.Image,
                hostname: body.Hostname ?? "",
                user: body.User ?? "",
                env: body.Env ?? [],
                cmd: body.Cmd?.values,
                entrypoint: body.Entrypoint?.values,
                workingDir: body.WorkingDir ?? "",
                labels: body.Labels ?? [:],
                tty: body.Tty ?? false,
                openStdin: body.OpenStdin ?? false,
                stdinOnce: body.StdinOnce ?? false,
                memory: body.HostConfig?.Memory ?? 0,
                nanoCpus: body.HostConfig?.NanoCpus ?? 0,
                autoRemove: body.HostConfig?.AutoRemove ?? false,
                networkMode: networkMode,
                volumeRequests: Self.volumeRequests(from: body),
                portBindings: try Self.portBindings(from: body),
                exposedPorts: try Self.exposedPorts(from: body),
                endpointRequests: try Self.endpointRequests(from: body, networkMode: networkMode),
                extraHosts: body.HostConfig?.ExtraHosts ?? [],
                dns: body.HostConfig?.Dns ?? [],
                dnsSearch: body.HostConfig?.DnsSearch ?? [],
                dnsOptions: body.HostConfig?.DnsOptions ?? [],
                restartPolicy: try Self.restartPolicy(body.HostConfig?.RestartPolicy),
                stopSignal: body.StopSignal ?? "",
                stopTimeout: body.StopTimeout ?? 0,
                privileged: body.HostConfig?.Privileged ?? false,
                readonlyRootfs: body.HostConfig?.ReadonlyRootfs ?? false,
                domainname: body.Domainname ?? "",
                groupAdd: body.HostConfig?.GroupAdd ?? [],
                publishAllPorts: body.HostConfig?.PublishAllPorts ?? false,
                volumesFrom: body.HostConfig?.VolumesFrom ?? [],
                healthcheck: body.Healthcheck.map {
                    EngineHealthcheck(
                        test: $0.Test ?? [],
                        intervalNanos: $0.Interval ?? 0,
                        timeoutNanos: $0.Timeout ?? 0,
                        startPeriodNanos: $0.StartPeriod ?? 0,
                        startIntervalNanos: $0.StartInterval ?? 0,
                        retries: $0.Retries ?? 0
                    )
                },
                useInit: body.HostConfig?.Init ?? false,
                capAdd: body.HostConfig?.CapAdd ?? [],
                capDrop: body.HostConfig?.CapDrop ?? []
            )
            if let driver = body.HostConfig?.VolumeDriver, !driver.isEmpty, driver != "local" {
                return Self.jsonError(status: 400, message: "volume driver \"\(driver)\" is not supported")
            }
        } catch {
            return Self.jsonError(status: 400, message: "invalid container config: \(error.localizedDescription)")
        }

        do {
            let result = try await engine.createContainer(spec)
            return HTTPResponse(
                status: 201,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerCreateContainerResponse(Id: result.id, Warnings: result.warnings)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    func pruneContainers(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let result = try await engine.pruneContainers(filters: Self.parseFilters(request.query["filters"]))
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerContainerPruneResponse(
                    ContainersDeleted: result.deleted,
                    SpaceReclaimed: result.spaceReclaimed
                )))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func inspectContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let inspected = try await engine.inspectContainer(id, size: Self.queryFlag(request.query["size"]))
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerContainerInspect(
                    inspected.container,
                    sizeRw: inspected.sizeRw,
                    sizeRootFs: inspected.sizeRootFs
                )))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func topContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let top = try await engine.containerTop(id, psArgs: request.query["ps_args"])
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerTopResponse(top)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func logsContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        let stdout = Self.queryFlag(request.query["stdout"])
        let stderr = Self.queryFlag(request.query["stderr"])
        guard stdout || stderr else {
            return Self.jsonError(status: 400, message: "you must choose at least one stream")
        }

        let timestamps = Self.queryFlag(request.query["timestamps"])
        let follow = Self.queryFlag(request.query["follow"])
        let details = Self.queryFlag(request.query["details"])
        let tail = request.query["tail"]
        let since = Self.parseTimestamp(request.query["since"])
        let until = Self.parseTimestamp(request.query["until"])

        _ = details // `--details` adds log attributes; Macker records none.

        do {
            let (entries, tty, live) = try await engine.containerLogs(id, follow: follow)
            var payload = Data()
            for entry in Self.selectLogEntries(entries, tail: tail, since: since, until: until) {
                payload += Self.framedIOChunk(
                    EngineIOChunk(data: Data(entry.text.utf8), stdout: entry.stdout, time: entry.time),
                    tty: tty,
                    stdout: stdout,
                    stderr: stderr,
                    timestamps: timestamps
                )
            }
            let headers = [("Content-Type", Self.streamContentType(tty: tty, version: request.apiVersion))]

            // `until` in the past ends a follow immediately, like Docker.
            guard follow, let session = live, until.map({ $0 > Date() }) ?? true else {
                await live?.close()
                var buffer = ByteBuffer()
                buffer.writeBytes(payload)
                return HTTPResponse(status: 200, headers: headers, body: .buffer(buffer))
            }

            let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
            Task {
                Self.yieldLog(payload, to: continuation)
                for await chunk in session.chunks {
                    if let until, let time = chunk.time, time > until { break }
                    Self.yieldLog(
                        Self.framedIOChunk(chunk, tty: tty, stdout: stdout, stderr: stderr, timestamps: timestamps),
                        to: continuation
                    )
                }
                continuation.finish()
            }
            return HTTPResponse(
                status: 200,
                headers: headers,
                body: .stream(.init(stream, onClose: { await session.close() }))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func statsContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        let oneShot = Self.queryFlag(request.query["one-shot"])
        let stream: Bool
        if oneShot {
            stream = false
        } else if request.query["stream"] == nil {
            stream = true
        } else {
            stream = Self.queryFlag(request.query["stream"])
        }
        do {
            if !stream {
                let stats = try await engine.containerStats(id)
                return HTTPResponse(
                    status: 200,
                    headers: [("Content-Type", "application/json")],
                    body: .buffer(JSONBody.encode(DockerContainerStats(stats)))
                )
            }
            let (chunks, continuation) = AsyncStream<ByteBuffer>.makeStream()
            let engine = self.engine
            let task = Task {
                while !Task.isCancelled {
                    do {
                        let stats = try await engine.containerStats(id)
                        continuation.yield(JSONBody.encodeLine(DockerContainerStats(stats)))
                    } catch {
                        continuation.finish()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .stream(.init(chunks, onClose: { task.cancel() }))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func startContainer(_ id: String) async -> HTTPResponse {
        do {
            let started = try await engine.startContainer(id)
            return HTTPResponse(status: started ? 204 : 304)
        } catch {
            return Self.engineError(error)
        }
    }

    private func stopContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let timeout = request.query["t"].flatMap(Int.init)
            let stopped = try await engine.stopContainer(
                id,
                timeoutSeconds: timeout,
                signal: request.query["signal"]
            )
            return HTTPResponse(status: stopped ? 204 : 304)
        } catch {
            return Self.engineError(error)
        }
    }

    private func restartContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let timeout = Int(request.query["t"] ?? "") ?? 10
            try await engine.restartContainer(id, timeoutSeconds: timeout)
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }

    private func killContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            try await engine.killContainer(id, signal: Self.querySignal(request.query["signal"]))
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }

    private func updateContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        let body: DockerUpdateContainerRequest
        if request.body.isEmpty {
            body = DockerUpdateContainerRequest(Memory: nil, NanoCpus: nil)
        } else {
            do {
                body = try JSONDecoder().decode(DockerUpdateContainerRequest.self, from: request.body)
            } catch {
                return Self.jsonError(status: 400, message: "invalid update config: \(error.localizedDescription)")
            }
        }
        do {
            try await engine.updateContainer(id, memory: body.Memory, nanoCpus: body.NanoCpus)
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerUpdateContainerResponse(Warnings: [])))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func renameContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let name = request.query["name"], !name.isEmpty else {
            return Self.jsonError(status: 400, message: "name query parameter is required")
        }
        do {
            try await engine.renameContainer(id, to: name)
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }

    /// Docker writes the 200 header at once and the JSON body when the condition is met.
    /// Clients (`docker run`) block on the header before calling `start`, so the waiter is
    /// registered before this returns and the body is streamed later.
    private func waitContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        let condition: EngineWaitCondition
        switch request.query["condition"] ?? "" {
        case "":
            condition = .notRunning
        case let raw:
            guard let parsed = EngineWaitCondition(rawValue: raw) else {
                return Self.jsonError(status: 400, message: "invalid condition: \"\(raw)\"")
            }
            condition = parsed
        }
        let exits: AsyncStream<Int>
        do {
            exits = try await engine.waitContainer(id, condition: condition)
        } catch {
            return Self.engineError(error)
        }
        let (body, continuation) = AsyncStream<ByteBuffer>.makeStream()
        let task = Task {
            var response = DockerWaitResponse(StatusCode: -1, Error: .init(Message: "wait canceled: daemon is shutting down"))
            for await code in exits {
                response = DockerWaitResponse(StatusCode: code)
                break
            }
            if !Task.isCancelled {
                continuation.yield(JSONBody.encodeLine(response))
            }
            continuation.finish()
        }
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: .stream(.init(body, onClose: { task.cancel() }))
        )
    }

    private func resizeContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            try await engine.resizeContainer(
                id,
                height: Int(request.query["h"] ?? "") ?? 0,
                width: Int(request.query["w"] ?? "") ?? 0
            )
            return HTTPResponse(status: 200)
        } catch {
            return Self.engineError(error)
        }
    }

    private func archiveContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        guard let path = request.query["path"], !path.isEmpty else {
            return Self.jsonError(status: 400, message: "path query parameter is required")
        }
        let method = request.method.uppercased()
        do {
            if method == "PUT" {
                try await engine.putArchive(
                    id,
                    path: path,
                    tar: request.body,
                    noOverwriteDirNonDir: Self.queryFlag(request.query["noOverwriteDirNonDir"])
                )
                return HTTPResponse(status: 200)
            }
            if method == "HEAD" {
                let stat = try await engine.archiveStat(id, path: path)
                return HTTPResponse(
                    status: 200,
                    headers: [("X-Docker-Container-Path-Stat", stat.dockerHeader)]
                )
            }
            let (stat, tar) = try await engine.getArchive(id, path: path)
            var buffer = ByteBuffer()
            buffer.writeBytes(tar)
            return HTTPResponse(
                status: 200,
                headers: [
                    ("Content-Type", "application/x-tar"),
                    ("X-Docker-Container-Path-Stat", stat.dockerHeader),
                ],
                body: .buffer(buffer)
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func exportContainer(_ id: String) async -> HTTPResponse {
        do {
            let tar = try await engine.exportContainer(id)
            var buffer = ByteBuffer()
            buffer.writeBytes(tar)
            return HTTPResponse(
                status: 200,
                headers: [
                    ("Content-Type", "application/x-tar"),
                    ("Content-Disposition", "attachment; filename=export.tar"),
                ],
                body: .buffer(buffer)
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func containerChanges(_ id: String) async -> HTTPResponse {
        do {
            return Self.jsonOK(try await engine.containerChanges(id).map(DockerFilesystemChange.init))
        } catch {
            return Self.engineError(error)
        }
    }

    private func deleteContainer(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            try await engine.deleteContainer(
                id,
                force: Self.queryFlag(request.query["force"]),
                removeAnonymousVolumes: Self.queryFlag(request.query["v"])
            )
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }

    private func mutateContainer(_ id: String, _ op: (EngineManager) async throws -> Void) async -> HTTPResponse {
        do {
            try await op(engine)
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }

    static func exposedPorts(from body: DockerCreateContainerRequest) throws -> [EnginePortBinding] {
        var ports: [EnginePortBinding] = []
        for key in body.ExposedPorts?.keys.sorted() ?? [] {
            ports.append(try EnginePortBinding.parseExposed(key))
        }
        for key in body.HostConfig?.PortBindings?.keys.sorted() ?? [] {
            ports.append(try EnginePortBinding.parseExposed(key))
        }
        return EnginePortBinding.uniqued(ports)
    }

    static func portBindings(from body: DockerCreateContainerRequest) throws -> [EnginePortBinding] {
        var bindings: [EnginePortBinding] = []
        for (key, published) in body.HostConfig?.PortBindings ?? [:] {
            let exposed = try EnginePortBinding.parseExposed(key)
            if published.isEmpty {
                bindings.append(
                    EnginePortBinding(
                        hostIP: "",
                        hostPort: 0,
                        containerPort: exposed.containerPort,
                        protocolName: exposed.protocolName
                    )
                )
                continue
            }
            for item in published {
                let hostPort = Int(item.HostPort ?? "") ?? 0
                bindings.append(
                    EnginePortBinding(
                        hostIP: item.HostIp ?? "",
                        hostPort: hostPort,
                        containerPort: exposed.containerPort,
                        protocolName: exposed.protocolName
                    )
                )
            }
        }
        return bindings
    }

    /// Docker's `"default"` network mode is `bridge` on Linux daemons.
    static func networkMode(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw != "default" else { return "bridge" }
        return raw
    }

    /// `EndpointsConfig` keys are network names; the official CLI keys the endpoint of the
    /// default network as `"default"`, which means whatever `NetworkMode` resolves to.
    static func endpointRequests(from body: DockerCreateContainerRequest, networkMode: String) throws -> [EngineEndpointRequest] {
        try (body.NetworkingConfig?.EndpointsConfig ?? [:]).sorted { $0.key < $1.key }.map { key, config in
            if let ip6 = config.IPAMConfig?.IPv6Address, !ip6.isEmpty {
                throw EngineError.notImplemented("IPv6 is not implemented")
            }
            let name = key == "default" ? networkMode : key
            return EngineEndpointRequest(
                network: name,
                aliases: Self.endpointAliases(config),
                ipv4: config.IPAMConfig?.IPv4Address,
                macAddress: config.MacAddress,
                driverOpts: config.DriverOpts ?? [:],
                gwPriority: config.GwPriority ?? 0,
                linkLocalIPs: config.IPAMConfig?.LinkLocalIPs ?? []
            )
        }
    }

    static func restartPolicy(_ policy: DockerCreateContainerRequest.HostConfig.RestartPolicy?) throws -> EngineRestartPolicy {
        guard let name = policy?.Name, !name.isEmpty else { return .none }
        if name == "on-failure" {
            return EngineRestartPolicy(name: "on-failure", maximumRetryCount: policy?.MaximumRetryCount ?? 0)
        }
        return try EngineRestartPolicy.parse(name)
    }

    static func volumeRequests(from body: DockerCreateContainerRequest) -> [EngineVolumeRequest] {
        var requests: [EngineVolumeRequest] = []
        for destination in body.Volumes?.keys.sorted() ?? [] {
            requests.append(
                EngineVolumeRequest(type: "volume", source: "", destination: destination, anonymous: true)
            )
        }
        for bind in body.HostConfig?.Binds ?? [] {
            if let parsed = parseBind(bind) {
                requests.append(parsed)
            }
        }
        for mount in body.HostConfig?.Mounts ?? [] {
            let destination = mount.Target ?? ""
            guard !destination.isEmpty else { continue }
            let type = (mount.`Type` ?? "volume").lowercased()
            if type == "tmpfs" {
                requests.append(EngineVolumeRequest(type: "tmpfs", source: "", destination: destination, readOnly: false))
                continue
            }
            // Other types are rejected by `DockerCreateValidator`.
            guard type == "bind" || type == "volume" else { continue }
            requests.append(
                EngineVolumeRequest(
                    type: type,
                    source: mount.Source ?? "",
                    destination: destination,
                    readOnly: mount.ReadOnly ?? false,
                    anonymous: type == "volume" && (mount.Source ?? "").isEmpty
                )
            )
        }
        for destination in body.HostConfig?.Tmpfs?.keys.sorted() ?? [] {
            requests.append(EngineVolumeRequest(type: "tmpfs", source: "", destination: destination, readOnly: false))
        }
        return requests
    }

    static func parseBind(_ bind: String) -> EngineVolumeRequest? {
        let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let source = parts[0]
        let destination = parts[1]
        let readOnly = parts.count >= 3 && parts[2].split(separator: ",").contains(where: { $0 == "ro" })
        let isBind = source.hasPrefix("/") || source.hasPrefix(".") || source.contains("\\")
        return EngineVolumeRequest(
            type: isBind ? "bind" : "volume",
            source: source,
            destination: destination,
            readOnly: readOnly,
            anonymous: false
        )
    }

    /// Docker `json-file` reading order: `tail` picks the last N lines, then `since`
    /// (inclusive) and `until` filter by log time.
    static func selectLogEntries(
        _ entries: [EngineLogEntry],
        tail: String?,
        since: Date? = nil,
        until: Date? = nil
    ) -> [EngineLogEntry] {
        var selected = entries
        if let tail, tail != "all", let count = Int(tail), count >= 0 {
            selected = Array(selected.suffix(count))
        }
        return selected.filter { entry in
            if let since, entry.time < since { return false }
            if let until, entry.time > until { return false }
            return true
        }
    }

    /// Non-TTY stdio is multiplexed (8-byte stream headers); API 1.42+ says so in the
    /// Content-Type.
    static func streamContentType(tty: Bool, version: DockerAPIVersion) -> String {
        !tty && version.atLeast("1.42") ? "application/vnd.docker.multiplexed-stream" : "application/vnd.docker.raw-stream"
    }

    static func dockerLogPayload(data: Data, tty: Bool, stdout: Bool) -> Data {
        guard !data.isEmpty else { return Data() }
        if tty {
            return data
        }
        return DockerStdio.frame(data, stdout: stdout)
    }

    /// One attach/exec/log chunk on the wire: dropped if its stream was not requested,
    /// optionally prefixed with its RFC 3339 log time, framed unless TTY.
    static func framedIOChunk(
        _ chunk: EngineIOChunk,
        tty: Bool,
        stdout: Bool,
        stderr: Bool,
        timestamps: Bool = false
    ) -> Data {
        if !tty {
            if chunk.stdout && !stdout { return Data() }
            if !chunk.stdout && !stderr { return Data() }
        }
        var data = chunk.data
        if timestamps {
            data = Data("\(ISO8601.string(from: chunk.time ?? Date())) ".utf8) + data
        }
        return dockerLogPayload(data: data, tty: tty, stdout: chunk.stdout)
    }

    static func yieldLog(_ payload: Data, to continuation: AsyncStream<ByteBuffer>.Continuation) {
        guard !payload.isEmpty else { return }
        var buffer = ByteBuffer()
        buffer.writeBytes(payload)
        continuation.yield(buffer)
    }
}
