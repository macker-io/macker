import ContainerEngine
import Foundation
import NIOCore

extension Router {
    static func ping(includeBody: Bool) -> HTTPResponse {
        var body: HTTPResponseBody = .none
        if includeBody {
            var buffer = ByteBuffer()
            buffer.writeString("OK")
            body = .buffer(buffer)
        }
        return HTTPResponse(
            status: 200,
            headers: [
                ("Content-Type", "text/plain; charset=utf-8"),
                ("Api-Version", DockerAPI.version),
                ("Docker-Experimental", "true"),
                ("Cache-Control", "no-cache, no-store, must-revalidate"),
                ("Pragma", "no-cache"),
            ],
            body: body
        )
    }

    static func version() -> HTTPResponse {
        Self.jsonOK(DockerVersionResponse.current())
    }

    func info() async -> HTTPResponse {
        Self.jsonOK(DockerSystemInfo(await engine.systemInfo()))
    }

    func systemDataUsage() async -> HTTPResponse {
        do {
            return Self.jsonOK(DockerDiskUsage(try await engine.diskUsage()))
        } catch {
            return Self.jsonError(status: 500, message: error.localizedDescription)
        }
    }

    func events(_ request: HTTPRequest) async -> HTTPResponse {
        let until = Self.parseTimestamp(request.query["until"])
        let filters = Self.parseFilters(request.query["filters"])
        let stream = await engine.events(until: until)
        let (out, continuation) = AsyncStream<ByteBuffer>.makeStream()
        Task {
            for await event in stream {
                if Self.matches(event, filters: filters) {
                    continuation.yield(JSONBody.encodeLine(DockerEvent(event)))
                }
            }
            continuation.finish()
        }
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: .stream(.init(out))
        )
    }

    func auth(_ request: HTTPRequest) async -> HTTPResponse {
        if request.body.isEmpty {
            return Self.jsonError(status: 400, message: "username and password required")
        }
        let config: AuthConfig
        do {
            config = try JSONDecoder().decode(AuthConfig.self, from: request.body)
        } catch {
            return Self.jsonError(status: 400, message: "invalid auth config: \(error.localizedDescription)")
        }
        do {
            try await engine.login(config)
            return Self.jsonOK(DockerAuthResponse(Status: "Login Succeeded", IdentityToken: ""))
        } catch {
            return Self.engineError(error)
        }
    }

    func logout(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            try await engine.logout(serverAddress: request.query["serveraddress"])
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }

    static func matches(_ event: EngineEvent, filters: [String: [String]]) -> Bool {
        if let types = filters["type"], !types.isEmpty, !types.contains(event.type) {
            return false
        }
        if let actions = filters["event"], !actions.isEmpty, !actions.contains(event.action) {
            return false
        }
        if let images = filters["image"], !images.isEmpty {
            let name = event.attributes["name"] ?? ""
            let hit = images.contains { name.contains($0) || event.actorID.contains($0) }
            if !hit { return false }
        }
        return true
    }
}
