import ContainerEngine
import Foundation
import NIOCore

extension Router {
    enum NamedExecRoute {
        case start(String)
        case inspect(String)
        case resize(String)
    }

    static func matchNamedExec(method: String, path: String) -> NamedExecRoute? {
        guard path.hasPrefix("/exec/") else { return nil }
        let rest = String(path.dropFirst("/exec/".count))
        guard !rest.isEmpty else { return nil }

        func decode(_ name: String) -> String {
            name.removingPercentEncoding ?? name
        }

        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let id = decode(String(rest[..<slash]))
        let action = String(rest[rest.index(after: slash)...])
        switch (method, action) {
        case ("POST", "start"):
            return .start(id)
        case ("GET", "json"):
            return .inspect(id)
        case ("POST", "resize"):
            return .resize(id)
        default:
            return nil
        }
    }

    func handleNamedExec(_ route: NamedExecRoute, request: HTTPRequest) async -> HTTPResponse {
        switch route {
        case .start(let id):
            return await startExec(id, request: request)
        case .inspect(let id):
            return await inspectExec(id)
        case .resize(let id):
            return await resizeExec(id, request: request)
        }
    }

    func createExec(_ containerID: String, request: HTTPRequest) async -> HTTPResponse {
        let spec: EngineExecCreateSpec
        do {
            let body = try JSONDecoder().decode(DockerCreateExecRequest.self, from: request.body)
            let cmd = body.Cmd?.values ?? []
            guard !cmd.isEmpty else {
                return Self.jsonError(status: 400, message: "No exec command specified")
            }
            spec = EngineExecCreateSpec(
                cmd: cmd,
                env: body.Env ?? [],
                user: body.User ?? "",
                workingDir: body.WorkingDir ?? "",
                tty: body.Tty ?? false,
                privileged: body.Privileged ?? false,
                attachStdin: body.AttachStdin ?? false,
                attachStdout: body.AttachStdout ?? true,
                attachStderr: body.AttachStderr ?? true,
                detachKeys: body.DetachKeys ?? ""
            )
        } catch {
            return Self.jsonError(status: 400, message: "invalid exec config: \(error.localizedDescription)")
        }

        do {
            let id = try await engine.createExec(containerID, spec: spec)
            return HTTPResponse(
                status: 201,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerCreateExecResponse(Id: id)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    func attachContainer(_ id: String, request: HTTPRequest, websocket: Bool) async -> HTTPResponse {
        do {
            let session = try await engine.attachContainer(
                id,
                logs: Self.queryFlag(request.query["logs"]),
                stream: Self.queryFlag(request.query["stream"]),
                stdin: Self.queryFlag(request.query["stdin"])
            )
            let stdout = Self.queryFlag(request.query["stdout"]) || !Self.queryFlag(request.query["stderr"])
            return Self.hijackResponse(
                session,
                request: request,
                stdout: stdout,
                kind: websocket ? .websocket : .tcp
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func startExec(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        let body: DockerExecStartRequest
        if request.body.isEmpty {
            body = DockerExecStartRequest()
        } else {
            do {
                body = try JSONDecoder().decode(DockerExecStartRequest.self, from: request.body)
            } catch {
                return Self.jsonError(status: 400, message: "invalid exec start config: \(error.localizedDescription)")
            }
        }

        do {
            let detach = body.Detach ?? false
            let session = try await engine.startExec(id, detach: detach, tty: body.Tty)
            if detach {
                return HTTPResponse(status: 200)
            }
            guard let session else {
                return HTTPResponse(status: 200)
            }
            return Self.hijackResponse(session, request: request, stdout: true, kind: .tcp)
        } catch {
            return Self.engineError(error)
        }
    }

    private func inspectExec(_ id: String) async -> HTTPResponse {
        do {
            let exec = try await engine.inspectExec(id)
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerExecInspect(exec)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func resizeExec(_ id: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            try await engine.resizeExec(
                id,
                height: Int(request.query["h"] ?? "") ?? 0,
                width: Int(request.query["w"] ?? "") ?? 0
            )
            return HTTPResponse(status: 201)
        } catch {
            return Self.engineError(error)
        }
    }

    static func hijackResponse(
        _ session: EngineIOSession,
        request: HTTPRequest,
        stdout: Bool,
        kind: DockerHijack.Kind
    ) -> HTTPResponse {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        Task {
            for await text in session.chunks {
                let payload = dockerLogPayload(text: text, tty: session.tty, stdout: stdout)
                if !payload.isEmpty {
                    var buffer = ByteBuffer()
                    buffer.writeBytes(payload)
                    continuation.yield(buffer)
                }
            }
            continuation.finish()
        }

        let upgrade = request.headers["upgrade"]?.lowercased() == "tcp"
        let status: UInt
        var headers: [(String, String)] = [("Content-Type", "application/vnd.docker.raw-stream")]
        switch kind {
        case .websocket:
            status = 101
        case .tcp:
            if upgrade {
                status = 101
                headers.append(("Connection", "Upgrade"))
                headers.append(("Upgrade", "tcp"))
            } else {
                status = 200
            }
        }

        return HTTPResponse(
            status: status,
            headers: headers,
            body: .hijack(
                DockerHijack(
                    kind: kind,
                    output: stream,
                    onStdin: { data in await session.writeStdin(data) },
                    onClose: { await session.close() }
                )
            )
        )
    }
}
