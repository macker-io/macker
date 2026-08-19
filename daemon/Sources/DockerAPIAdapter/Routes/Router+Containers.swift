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
            return await waitContainer(id)
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
                memory: body.HostConfig?.Memory ?? 0,
                nanoCpus: body.HostConfig?.NanoCpus ?? 0,
                autoRemove: body.HostConfig?.AutoRemove ?? false,
                networkMode: body.HostConfig?.NetworkMode ?? "default",
                volumeRequests: Self.volumeRequests(from: body),
                portBindings: try Self.portBindings(from: body),
                exposedPorts: try Self.exposedPorts(from: body),
                endpointRequests: Self.endpointRequests(from: body)
            )
        } catch {
            return Self.jsonError(status: 400, message: "invalid container config: \(error.localizedDescription)")
        }

        do {
            let result = try await engine.createContainer(spec)
            return HTTPResponse(
                status: 201,
                headers: [
                    ("Content-Type", "application/json"),
                    ("Location", "/v1.41/containers/\(result.id)"),
                ],
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

        do {
            let (text, tty, live) = try await engine.containerLogs(id, follow: follow)
            let formatted = Self.formatLogs(
                text,
                timestamps: timestamps,
                tail: tail,
                since: since,
                until: until,
                details: details
            )
            let payload = Self.dockerLogPayload(text: formatted, tty: tty, stdout: stdout)

            guard follow, let session = live else {
                var buffer = ByteBuffer()
                buffer.writeBytes(payload)
                return HTTPResponse(
                    status: 200,
                    headers: [("Content-Type", "application/vnd.docker.raw-stream")],
                    body: .buffer(buffer)
                )
            }

            let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
            Task {
                Self.yieldLog(payload, to: continuation)
                for await chunk in session.chunks {
                    Self.yieldLog(
                        Self.framedIOChunk(
                            chunk,
                            tty: tty,
                            stdout: stdout,
                            stderr: stderr,
                            timestamps: timestamps,
                            since: since,
                            until: until
                        ),
                        to: continuation
                    )
                }
                continuation.finish()
            }
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/vnd.docker.raw-stream")],
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
            let timeout = Int(request.query["t"] ?? "") ?? 10
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

    private func waitContainer(_ id: String) async -> HTTPResponse {
        do {
            let code = try await engine.waitContainer(id)
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerWaitResponse(StatusCode: code)))
            )
        } catch {
            return Self.engineError(error)
        }
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

    static func endpointRequests(from body: DockerCreateContainerRequest) -> [EngineEndpointRequest] {
        (body.NetworkingConfig?.EndpointsConfig ?? [:]).map { name, config in
            EngineEndpointRequest(
                network: name,
                aliases: Self.endpointAliases(config),
                ipv4: config.IPAMConfig?.IPv4Address,
                driverOpts: config.DriverOpts ?? [:],
                gwPriority: config.GwPriority ?? 0,
                linkLocalIPs: config.IPAMConfig?.LinkLocalIPs ?? []
            )
        }
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
            requests.append(
                EngineVolumeRequest(
                    type: type == "bind" ? "bind" : "volume",
                    source: mount.Source ?? "",
                    destination: destination,
                    readOnly: mount.ReadOnly ?? false,
                    anonymous: type != "bind" && (mount.Source ?? "").isEmpty
                )
            )
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

    static func formatLogs(
        _ text: String,
        timestamps: Bool,
        tail: String?,
        since: Date? = nil,
        until: Date? = nil,
        details: Bool = false
    ) -> String {
        _ = details
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }
        if since != nil || until != nil {
            lines = lines.filter { line in
                guard let stamp = logTimestamp(line) else { return true }
                if let since, stamp < since { return false }
                if let until, stamp > until { return false }
                return true
            }
        }
        if let tail, tail != "all", let count = Int(tail), count >= 0 {
            lines = Array(lines.suffix(count))
        }
        if timestamps {
            lines = lines.map { line in
                if line.isEmpty { return line }
                if logTimestamp(line) != nil { return line }
                return "\(ISO8601.string(from: Date())) \(line)"
            }
        }
        var result = lines.joined(separator: "\n")
        if hadTrailingNewline, !lines.isEmpty {
            result += "\n"
        }
        return result
    }

    static func logTimestamp(_ line: String) -> Date? {
        let token = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? line
        return ISO8601.parse(token)
    }

    static func dockerLogPayload(text: String, tty: Bool, stdout: Bool) -> Data {
        dockerLogPayload(data: Data(text.utf8), tty: tty, stdout: stdout)
    }

    static func dockerLogPayload(data: Data, tty: Bool, stdout: Bool) -> Data {
        guard !data.isEmpty else { return Data() }
        if tty {
            return data
        }
        return DockerStdio.frame(data, stdout: stdout)
    }

    static func framedIOChunk(
        _ chunk: EngineIOChunk,
        tty: Bool,
        stdout: Bool,
        stderr: Bool,
        timestamps: Bool = false,
        since: Date? = nil,
        until: Date? = nil
    ) -> Data {
        if !tty {
            if chunk.stdout && !stdout { return Data() }
            if !chunk.stdout && !stderr { return Data() }
        }
        let data: Data
        if timestamps || since != nil || until != nil {
            data = Data(
                formatLogs(
                    String(decoding: chunk.data, as: UTF8.self),
                    timestamps: timestamps,
                    tail: nil,
                    since: since,
                    until: until
                ).utf8
            )
        } else {
            data = chunk.data
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
