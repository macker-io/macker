import ContainerEngine
import Foundation

/// Minimal Docker Engine API router. Strips an optional `/v1.41` prefix.
public struct Router: Sendable {
    let engine: EngineManager

    public init(engine: EngineManager) {
        self.engine = engine
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let (apiVersion, path) = Self.splitAPIVersion(request.path)
        if let apiVersion, apiVersion != DockerAPI.version {
            return Self.jsonError(
                status: 400,
                message: "client version \(apiVersion) is too new. Maximum supported API version is \(DockerAPI.version)"
            )
        }

        let method = request.method.uppercased()
        switch (method, path) {
        case ("GET", "/_ping"):
            return Self.ping(includeBody: true)
        case ("HEAD", "/_ping"):
            return Self.ping(includeBody: false)
        case ("GET", "/version"):
            return Self.version()
        case ("GET", "/info"):
            return await info()
        case ("GET", "/events"):
            return await events(request)
        case ("GET", "/system/df"):
            return await systemDataUsage()
        case ("POST", "/auth"):
            return Self.auth(request)
        case ("GET", "/containers/json"):
            return await containersJSON(request)
        case ("POST", "/containers/create"):
            return await createContainer(request)
        case ("POST", "/containers/prune"):
            return await pruneContainers()
        case ("GET", "/images/json"):
            return await imagesJSON(request)
        case ("POST", "/images/create"):
            return await createImage(request)
        case ("GET", "/images/search"):
            return await searchImages(request)
        case ("GET", "/images/get"):
            return await exportImages(request.queryAll["names"] ?? request.query["names"].map { [$0] } ?? [])
        case ("POST", "/images/load"):
            return await loadImages(request)
        case ("POST", "/images/prune"):
            return await pruneImages(request)
        case ("GET", "/volumes"):
            return await listVolumes(request)
        case ("POST", "/volumes/create"):
            return await createVolume(request)
        case ("POST", "/volumes/prune"):
            return await pruneVolumes(request)
        case ("GET", "/networks"):
            return await listNetworks(request)
        case ("POST", "/networks/create"):
            return await createNetwork(request)
        case ("POST", "/networks/prune"):
            return await pruneNetworks(request)
        case ("POST", "/build"), ("POST", "/build/prune"), ("POST", "/commit"):
            return Self.jsonError(status: 501, message: "image build/commit is not implemented")
        default:
            if let route = Self.matchNamedContainer(method: method, path: path) {
                return await handleNamedContainer(route, request: request)
            }
            if let route = Self.matchNamedExec(method: method, path: path) {
                return await handleNamedExec(route, request: request)
            }
            if let route = Self.matchNamedVolume(method: method, path: path) {
                return await handleNamedVolume(route, request: request)
            }
            if let route = Self.matchNamedNetwork(method: method, path: path) {
                return await handleNamedNetwork(route, request: request)
            }
            if let route = Self.matchNamedImage(method: method, path: path) {
                return await handleNamedImage(route, request: request)
            }
            return Self.jsonError(status: 404, message: "page not found")
        }
    }

    /// Splits `/v1.41/version` → `("1.41", "/version")`. Unversioned paths keep `version == nil`.
    static func splitAPIVersion(_ path: String) -> (version: String?, path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            return (nil, path)
        }

        let candidate = parts[1]
        guard candidate.first == "v" else {
            return (nil, path)
        }

        let version = String(candidate.dropFirst())
        let isAPIVersion = !version.isEmpty
            && version.contains(".")
            && version.allSatisfy { $0.isNumber || $0 == "." }
        guard isAPIVersion else {
            return (nil, path)
        }

        let rest = parts.dropFirst(2).joined(separator: "/")
        return (version, rest.isEmpty ? "/" : "/\(rest)")
    }

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601.parse(raw)
    }

    static func parseFilters(_ raw: String?) -> [String: [String]] {
        guard let raw, let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    static func queryFlag(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return ["1", "true", "True", "TRUE", "yes"].contains(raw)
    }

    static func engineError(_ error: Error) -> HTTPResponse {
        if let error = error as? EngineError {
            switch error {
            case .imageNotFound, .containerNotFound, .execNotFound, .volumeNotFound, .networkNotFound:
                return jsonError(status: 404, message: error.localizedDescription)
            case .invalidReference, .invalidArgument:
                return jsonError(status: 400, message: error.localizedDescription)
            case .conflict:
                return jsonError(status: 409, message: error.localizedDescription)
            case .notImplemented:
                return jsonError(status: 501, message: error.localizedDescription)
            default:
                return jsonError(status: 500, message: error.localizedDescription)
            }
        }
        return jsonError(status: 500, message: error.localizedDescription)
    }

    static func jsonError(status: UInt, message: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json")],
            body: .buffer(JSONBody.encode(DockerErrorResponse(message: message)))
        )
    }

    static func jsonOK(_ value: some Encodable, status: UInt = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json")],
            body: .buffer(JSONBody.encode(value))
        )
    }
}
