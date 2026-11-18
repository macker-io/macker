import ContainerEngine
import Foundation

/// Minimal Docker Engine API router. Strips an optional `/v<major>.<minor>` prefix and
/// records the negotiated version on the request.
public struct Router: Sendable {
    let engine: EngineManager

    public init(engine: EngineManager) {
        self.engine = engine
    }

    public func handle(_ incoming: HTTPRequest) async -> HTTPResponse {
        let (rawVersion, path) = Self.splitAPIVersion(incoming.path)
        var request = incoming
        switch DockerAPIVersionPolicy.resolve(rawVersion) {
        case .success(let version):
            request.apiVersion = version
        case .failure(let error):
            return Self.jsonError(status: 400, message: error.message)
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
        case ("GET", "/macker/status"):
            return await mackerStatus()
        case ("GET", "/events"):
            return await events(request)
        case ("GET", "/system/df"):
            return await systemDataUsage()
        case ("POST", "/auth"):
            return await auth(request)
        case ("DELETE", "/auth"):
            return await logout(request)
        case ("GET", "/containers/json"):
            return await containersJSON(request)
        case ("POST", "/containers/create"):
            return await createContainer(request)
        case ("POST", "/containers/prune"):
            return await pruneContainers(request)
        case ("GET", "/images/json"):
            return await imagesJSON(request)
        case ("POST", "/images/create"):
            return await createImage(request)
        case ("GET", "/images/search"):
            return await searchImages(request)
        case ("GET", "/images/get"):
            return await exportImages(request.queryAll["names"] ?? request.query["names"].map { [$0] } ?? [], request: request)
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
        case ("POST", "/build"):
            return await buildImage(request)
        case ("POST", "/build/prune"):
            return await pruneBuildCache(request)
        case ("POST", "/commit"):
            return await commitContainer(request)
        case ("POST", "/grpc"):
            let proxy = BuildKitProxy(engine: engine)
            return HTTPResponse(status: 101, body: .upgrade(HTTPUpgrade(protocolName: "h2c") { proxy.serveGRPC(on: $0) }))
        case ("POST", "/session"):
            let proxy = BuildKitProxy(engine: engine)
            let headers = request.headerList
            return HTTPResponse(
                status: 101,
                body: .upgrade(HTTPUpgrade(protocolName: "h2c") { proxy.serveSession(on: $0, headers: headers) })
            )
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
            if let checkpoint = Self.matchCheckpoint(method: method, path: path) {
                return await checkpointResponse(checkpoint)
            }
            if let plugin = Self.pluginResponse(method: method, path: path, query: request.query) {
                return plugin
            }
            if let swarm = Self.swarmResponse(method: method, path: path) {
                return swarm
            }
            if method == "GET", let name = Self.distributionName(path) {
                return await distributionInspect(name, request: request)
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
        return ISO8601.parseTimestamp(raw)
    }

    static func parseGoDuration(_ raw: String) -> TimeInterval? {
        ISO8601.parseGoDuration(raw)
    }

    /// Docker `filters` query JSON. The official CLI sends the map form
    /// `{"label":{"a=b":true}}`; older clients (and `macker`) send `{"label":["a=b"]}`.
    /// Both decode to `key -> values` (map-form values are the inner keys, sorted).
    static func parseFilters(_ raw: String?) -> [String: [String]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        if let lists = try? decoder.decode([String: [String]].self, from: data) {
            return lists
        }
        if let maps = try? decoder.decode([String: [String: Bool]].self, from: data) {
            return maps.mapValues { $0.keys.sorted() }
        }
        return [:]
    }

    /// Docker `--link name:alias` contributes the alias (or the whole value if there is no `:`).
    static func endpointAliases(_ config: DockerEndpointConfig?) -> [String] {
        var aliases = config?.Aliases ?? []
        for link in config?.Links ?? [] {
            let alias = link.split(separator: ":").last.map(String.init) ?? link
            if !alias.isEmpty, !aliases.contains(alias) {
                aliases.append(alias)
            }
        }
        return aliases
    }

    static func queryFlag(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return ["1", "true", "True", "TRUE", "yes"].contains(raw)
    }

    static func querySignal(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "SIGKILL" }
        return raw
    }

    static func engineError(_ error: Error) -> HTTPResponse {
        if let error = error as? EngineError {
            switch error {
            case .imageNotFound, .containerNotFound, .execNotFound, .volumeNotFound, .networkNotFound:
                return jsonError(status: 404, message: error.localizedDescription)
            case .invalidReference, .invalidArgument:
                return jsonError(status: 400, message: error.localizedDescription)
            case .unauthorized:
                return jsonError(status: 401, message: error.localizedDescription)
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
