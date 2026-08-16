import ContainerEngine
import Foundation
import NIOCore

extension Router {
    enum NamedContainerRoute {
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
        case unsupported(String)
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
            case ("GET", "changes"), ("GET", "export"),
                ("GET", "archive"), ("HEAD", "archive"), ("PUT", "archive"):
                return .unsupported(id)
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
            return await inspectContainer(id)
        case .top(let id):
            return await topContainer(id)
        case .logs(let id):
            return await logsContainer(id, request: request)
        case .stats(let id):
            return await statsContainer(id)
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
        case .unsupported:
            return Self.jsonError(status: 501, message: "this container endpoint is not implemented")
        }
    }

    func containersJSON(_ request: HTTPRequest) async -> HTTPResponse {
        let all = Self.queryFlag(request.query["all"])
        let filters = Self.parseFilters(request.query["filters"])
        var containers = await engine.listContainers(all: all, filters: filters).map(DockerContainerSummary.init)
        if let limit = Int(request.query["limit"] ?? ""), limit >= 0 {
            containers = Array(containers.prefix(limit))
        }
        return Self.jsonOK(containers)
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

    func pruneContainers() async -> HTTPResponse {
        let result = await engine.pruneContainers()
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: .buffer(JSONBody.encode(DockerContainerPruneResponse(
                ContainersDeleted: result.deleted,
                SpaceReclaimed: result.spaceReclaimed
            )))
        )
    }

    private func inspectContainer(_ id: String) async -> HTTPResponse {
        do {
            let container = try await engine.inspectContainer(id)
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerContainerInspect(container)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func topContainer(_ id: String) async -> HTTPResponse {
        do {
            let top = try await engine.containerTop(id)
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
        let tail = request.query["tail"]

        do {
            let (text, tty, live) = try await engine.containerLogs(id, follow: follow)
            let formatted = Self.formatLogs(text, timestamps: timestamps, tail: tail)
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
                            timestamps: timestamps
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

    private func statsContainer(_ id: String) async -> HTTPResponse {
        do {
            let container = try await engine.inspectContainer(id)
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerContainerStats(memoryLimit: container.memory)))
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
            let stopped = try await engine.stopContainer(id, timeoutSeconds: timeout)
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
            try await engine.killContainer(id, signal: request.query["signal"] ?? "SIGKILL")
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
            EngineEndpointRequest(network: name, aliases: config.Aliases ?? [])
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

    static func formatLogs(_ text: String, timestamps: Bool, tail: String?) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let tail, tail != "all", let count = Int(tail), count >= 0 {
            lines = Array(lines.suffix(count))
        }
        if timestamps {
            let stamp = ISO8601DateFormatter().string(from: Date())
            lines = lines.map { $0.isEmpty ? $0 : "\(stamp) \($0)" }
        }
        return lines.joined(separator: "\n")
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
        timestamps: Bool = false
    ) -> Data {
        if !tty {
            if chunk.stdout && !stdout { return Data() }
            if !chunk.stdout && !stderr { return Data() }
        }
        let data: Data
        if timestamps {
            data = Data(
                formatLogs(String(decoding: chunk.data, as: UTF8.self), timestamps: true, tail: nil).utf8
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
