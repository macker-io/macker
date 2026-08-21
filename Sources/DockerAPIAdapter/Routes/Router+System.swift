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
        let since = Self.parseTimestamp(request.query["since"])
        let until = Self.parseTimestamp(request.query["until"])
        let filters = Self.parseFilters(request.query["filters"])
        let stream = await engine.events(since: since, until: until)
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
        guard match(filters["type"], event.type) else { return false }
        guard match(filters["event"], event.action) else { return false }
        if let images = filters["image"], !images.isEmpty {
            let refs = [event.actorID, event.attributes["name"] ?? "", event.attributes["image"] ?? ""]
            if !images.contains(where: { needle in refs.contains { $0.contains(needle) } }) {
                return false
            }
        }
        if !matchesActor(event, type: "container", keys: filters["container"]) { return false }
        if !matchesActor(event, type: "volume", keys: filters["volume"]) { return false }
        if !matchesActor(event, type: "network", keys: filters["network"]) { return false }
        return true
    }

    private static func match(_ allowed: [String]?, _ value: String) -> Bool {
        guard let allowed, !allowed.isEmpty else { return true }
        return allowed.contains(value)
    }

    private static func matchesActor(_ event: EngineEvent, type: String, keys: [String]?) -> Bool {
        guard let keys, !keys.isEmpty else { return true }
        guard event.type == type else { return false }
        let name = event.attributes["name"] ?? ""
        return keys.contains { event.actorID.contains($0) || name.contains($0) }
    }
}
