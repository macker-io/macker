import ContainerizationOCI
import Foundation

/// `GET /v2/<repo>/tags/list` with the Docker Bearer-token dance.
/// The vendored `RegistryClient` keeps its token flow internal, so tag listing
/// (needed by `pull --all-tags`) re-implements it over URLSession.
enum RegistryTags {
    /// Every tag of `reference` (a repository without tag/digest, e.g. `docker.io/library/alpine`).
    static func list(reference: String, auth: Authentication?) async throws -> [String] {
        let parsed: Reference
        do {
            parsed = try Reference.parse(reference)
        } catch {
            throw EngineError.invalidReference("invalid image reference \(reference)")
        }
        guard let domain = parsed.resolvedDomain else {
            throw EngineError.invalidReference("invalid image reference \(reference)")
        }
        let endpoint = registryEndpoint(domain)
        let basic = try await auth?.token()
        let fallbackScope = "repository:\(parsed.path):pull"
        do {
            return try await fetchAllTags(
                host: endpoint.host,
                port: endpoint.port,
                scheme: "https",
                repository: parsed.path,
                basic: basic,
                fallbackScope: fallbackScope
            )
        } catch let error as EngineError {
            throw error
        } catch {
            // TLS / connection failures (typical HTTP registries on localhost:5000).
            return try await fetchAllTags(
                host: endpoint.host,
                port: endpoint.port,
                scheme: "http",
                repository: parsed.path,
                basic: basic,
                fallbackScope: fallbackScope
            )
        }
    }

    /// Hub's registry hostname plus `host:port` split so URLComponents gets a real host.
    static func registryEndpoint(_ domain: String) -> (host: String, port: Int?) {
        let mapped: String
        switch domain.lowercased() {
        case "docker.io", "index.docker.io":
            mapped = "registry-1.docker.io"
        default:
            mapped = domain
        }
        return splitHostPort(mapped)
    }

    static func splitHostPort(_ value: String) -> (host: String, port: Int?) {
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.first == ":", let port = Int(rest.dropFirst()) {
                return (host, port)
            }
            return (host, nil)
        }
        guard let colon = value.lastIndex(of: ":"), !value[..<colon].contains(":"),
            let port = Int(value[value.index(after: colon)...])
        else {
            return (value, nil)
        }
        return (String(value[..<colon]), port)
    }

    /// Exchanges a `Bearer realm=…,service=…,scope=…` challenge for a token.
    /// Returns nil for non-Bearer challenges (e.g. Basic-only registries).
    static func fetchBearer(challenge: String, basic: String?, fallbackScope: String) async throws -> String? {
        guard challenge.lowercased().hasPrefix("bearer ") else { return nil }
        let params = parseAuthParams(String(challenge.dropFirst("Bearer ".count)))
        guard let realm = params["realm"], var components = URLComponents(string: realm) else { return nil }
        var query = [URLQueryItem(name: "service", value: params["service"] ?? "")]
        query.append(URLQueryItem(name: "scope", value: params["scope"] ?? fallbackScope))
        query.append(URLQueryItem(name: "client_id", value: "macker"))
        components.queryItems = query
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 30)
        if let basic {
            request.setValue(basic, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EngineError.unauthorized("registry token request failed")
        }
        let body = try JSONDecoder().decode(TokenBody.self, from: data)
        guard let token = body.token ?? body.accessToken else {
            throw EngineError.unauthorized("registry token response had no token")
        }
        return token
    }

    /// Parses `key="value"` pairs from a WWW-Authenticate challenge.
    static func parseAuthParams(_ text: String) -> [String: String] {
        var params: [String: String] = [:]
        let pattern = #"(\w+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return params }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) {
                params[String(text[key])] = String(text[value])
            }
        }
        return params
    }

    /// Extracts the `last` cursor from a pagination `Link` header (`rel=next` or `rel="next"`).
    static func nextCursor(link: String?) -> String? {
        guard let link, isNextLink(link),
            let open = link.firstIndex(of: "<"), let close = link.firstIndex(of: ">"), open < close
        else { return nil }
        let target = String(link[link.index(after: open)..<close])
        guard let components = URLComponents(string: target) else { return nil }
        return components.queryItems?.first { $0.name == "last" }?.value
    }

    private static func fetchAllTags(
        host: String,
        port: Int?,
        scheme: String,
        repository: String,
        basic: String?,
        fallbackScope: String
    ) async throws -> [String] {
        var bearer: String?
        var cursor: String?
        var tags: [String] = []
        while true {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = port
            components.path = "/v2/\(repository)/tags/list"
            if let cursor {
                components.queryItems = [URLQueryItem(name: "last", value: cursor)]
            }
            guard let url = components.url else {
                throw EngineError.invalidReference("invalid registry host \(host)")
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            if let bearer {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            } else if let basic {
                request.setValue(basic, forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw EngineError.pullFailed("no response from registry \(host)")
            }
            if http.statusCode == 401, bearer == nil {
                guard let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
                    let token = try await fetchBearer(challenge: challenge, basic: basic, fallbackScope: fallbackScope)
                else {
                    throw EngineError.unauthorized("authentication required for \(repository)")
                }
                bearer = token
                continue
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw EngineError.unauthorized("authentication required for \(repository)")
            }
            if http.statusCode == 404 {
                throw EngineError.pullFailed("repository \(repository) not found")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw EngineError.pullFailed("registry \(host) returned HTTP \(http.statusCode)")
            }

            let page: TagsPage
            do {
                page = try JSONDecoder().decode(TagsPage.self, from: data)
            } catch {
                throw EngineError.pullFailed("invalid tags list from registry \(host)")
            }
            tags.append(contentsOf: page.tags ?? [])
            guard let next = nextCursor(link: http.value(forHTTPHeaderField: "Link")) else { break }
            cursor = next
        }
        return tags
    }

    private static func isNextLink(_ link: String) -> Bool {
        link.range(of: #"rel\s*=\s*"?next"?"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private struct TagsPage: Decodable {
    let tags: [String]?
}

private struct TokenBody: Decodable {
    let token: String?
    let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case token
        case accessToken = "access_token"
    }
}
