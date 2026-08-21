import ContainerizationOCI
import Foundation

/// Docker-compatible registry credentials stored next to the image store (`auth.json`).
struct RegistryAuthStore: Sendable {
    static let dockerHubIndex = "https://index.docker.io/v1/"
    static let dockerHubRegistry = "registry-1.docker.io"

    let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("auth.json")
    }

    func save(server: String, username: String, password: String) throws {
        var file = load()
        let canonical = Self.canonicalServer(server)
        for key in Self.lookupKeys(for: canonical) {
            file.auths.removeValue(forKey: key)
        }
        file.auths[canonical] = AuthEntry(auth: Self.encodeAuth(username: username, password: password))
        try persist(file)
    }

    func delete(server: String) throws {
        var file = load()
        for key in Self.lookupKeys(for: server) {
            file.auths.removeValue(forKey: key)
        }
        try persist(file)
    }

    func credentials(forServer server: String) -> (username: String, password: String)? {
        let file = load()
        for key in Self.lookupKeys(for: server) {
            if let entry = file.auths[key], let decoded = Self.decodeAuth(entry.auth) {
                return decoded
            }
        }
        return nil
    }

    /// Header credentials win when they include a username and password; otherwise the store is used.
    func authentication(reference: String, header: String?) -> Authentication? {
        if let headerAuth = Self.parseHeader(header) {
            return BasicAuthentication(username: headerAuth.username, password: headerAuth.password)
        }
        let server: String
        if let parsed = try? Reference.parse(reference), let domain = parsed.domain {
            server = domain
        } else {
            server = "docker.io"
        }
        guard let creds = credentials(forServer: server) else { return nil }
        return BasicAuthentication(username: creds.username, password: creds.password)
    }

    static func canonicalServer(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || isDockerHub(trimmed) {
            return dockerHubIndex
        }
        return hostPort(from: trimmed)
    }

    static func registryHost(_ canonical: String) -> (host: String, port: Int?) {
        let value = canonical == dockerHubIndex ? dockerHubRegistry : hostPort(from: canonical)
        return splitHostPort(value)
    }

    static func parseHeader(_ value: String?) -> (username: String, password: String)? {
        guard let value, !value.isEmpty, let data = base64Decode(value) else { return nil }
        guard let decoded = try? JSONDecoder().decode(AuthConfig.self, from: data) else { return nil }
        return credentials(from: decoded)
    }

    static func decodeAuth(_ auth: String) -> (username: String, password: String)? {
        guard let data = base64Decode(auth), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let split = text.firstIndex(of: ":") else { return nil }
        return (String(text[..<split]), String(text[text.index(after: split)...]))
    }

    static func credentials(from config: AuthConfig) -> (username: String, password: String)? {
        var user = config.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var pass = config.password ?? ""
        if let token = config.identitytoken, !token.isEmpty, pass.isEmpty {
            pass = token
        }
        if (user.isEmpty || pass.isEmpty), let auth = config.auth, let decoded = decodeAuth(auth) {
            if user.isEmpty { user = decoded.username }
            if pass.isEmpty { pass = decoded.password }
        }
        guard !user.isEmpty, !pass.isEmpty else { return nil }
        return (user, pass)
    }

    static func lookupKeys(for server: String) -> [String] {
        let canonical = canonicalServer(server)
        if canonical == dockerHubIndex {
            return [
                dockerHubIndex,
                "docker.io",
                "index.docker.io",
                dockerHubRegistry,
                "https://registry-1.docker.io",
                "https://index.docker.io/v1",
            ]
        }
        return [canonical, "https://\(canonical)", "http://\(canonical)"]
    }

    private func load() -> AuthFile {
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(AuthFile.self, from: data)
        else {
            return AuthFile(auths: [:])
        }
        return file
    }

    private func persist(_ file: AuthFile) throws {
        if file.auths.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func encodeAuth(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private static func isDockerHub(_ raw: String) -> Bool {
        switch hostPort(from: raw) {
        case "docker.io", "index.docker.io", dockerHubRegistry:
            return true
        default:
            return false
        }
    }

    private static func hostPort(from raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("https://") {
            value = String(value.dropFirst("https://".count))
        } else if value.lowercased().hasPrefix("http://") {
            value = String(value.dropFirst("http://".count))
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        while value.hasSuffix("/") {
            value = String(value.dropLast())
        }
        return value.lowercased()
    }

    private static func splitHostPort(_ value: String) -> (host: String, port: Int?) {
        guard let colon = value.lastIndex(of: ":"), !value[..<colon].contains(":"),
            let port = Int(value[value.index(after: colon)...])
        else {
            return (value, nil)
        }
        return (String(value[..<colon]), port)
    }

    private static func base64Decode(_ value: String) -> Data? {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = encoded.count % 4
        if pad > 0 {
            encoded += String(repeating: "=", count: 4 - pad)
        }
        return Data(base64Encoded: encoded)
    }
}

/// Docker `POST /auth` body and `X-Registry-Auth` JSON payload.
public struct AuthConfig: Codable, Sendable {
    public var username: String?
    public var password: String?
    public var email: String?
    public var serveraddress: String?
    public var identitytoken: String?
    public var auth: String?

    public init(
        username: String? = nil,
        password: String? = nil,
        email: String? = nil,
        serveraddress: String? = nil,
        identitytoken: String? = nil,
        auth: String? = nil
    ) {
        self.username = username
        self.password = password
        self.email = email
        self.serveraddress = serveraddress
        self.identitytoken = identitytoken
        self.auth = auth
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(serveraddress, forKey: .serveraddress)
        try container.encodeIfPresent(identitytoken, forKey: .identitytoken)
        try container.encodeIfPresent(auth, forKey: .auth)
    }
}

private struct AuthFile: Codable {
    var auths: [String: AuthEntry]
}

private struct AuthEntry: Codable {
    var auth: String
}
