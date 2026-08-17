import Foundation

public struct EngineCommitSpec: Sendable {
    public var repo: String?
    public var tag: String?
    public var comment: String
    public var author: String
    public var changes: [String]
    public var config: EngineCommitConfig?

    public init(
        repo: String? = nil,
        tag: String? = nil,
        comment: String = "",
        author: String = "",
        changes: [String] = [],
        config: EngineCommitConfig? = nil
    ) {
        self.repo = repo
        self.tag = tag
        self.comment = comment
        self.author = author
        self.changes = changes
        self.config = config
    }
}

public struct EngineCommitConfig: Sendable {
    public var user: String?
    public var env: [String]?
    public var cmd: [String]?
    public var entrypoint: [String]?
    public var workingDir: String?
    public var labels: [String: String]?
    public var exposedPorts: [String]?
    public var volumes: [String]?

    public init(
        user: String? = nil,
        env: [String]? = nil,
        cmd: [String]? = nil,
        entrypoint: [String]? = nil,
        workingDir: String? = nil,
        labels: [String: String]? = nil,
        exposedPorts: [String]? = nil,
        volumes: [String]? = nil
    ) {
        self.user = user
        self.env = env
        self.cmd = cmd
        self.entrypoint = entrypoint
        self.workingDir = workingDir
        self.labels = labels
        self.exposedPorts = exposedPorts
        self.volumes = volumes
    }
}

struct CommitImageFile: Codable, Sendable {
    var created: String?
    var author: String?
    var architecture: String
    var os: String
    var osVersion: String?
    var osFeatures: [String]?
    var variant: String?
    var config: CommitRuntimeConfig?
    var rootfs: CommitRootFS
    var history: [CommitHistory]?
}

struct CommitRuntimeConfig: Codable, Sendable {
    var User: String?
    var Env: [String]?
    var Entrypoint: [String]?
    var Cmd: [String]?
    var WorkingDir: String?
    var Labels: [String: String]?
    var StopSignal: String?
    var ExposedPorts: [String: CommitEmpty]?
    var Volumes: [String: CommitEmpty]?
}

struct CommitRootFS: Codable, Sendable {
    var type: String
    var diffIDs: [String]

    enum CodingKeys: String, CodingKey {
        case type
        case diffIDs = "diff_ids"
    }
}

struct CommitHistory: Codable, Sendable {
    var created: String?
    var createdBy: String?
    var author: String?
    var comment: String?
    var emptyLayer: Bool?

    enum CodingKeys: String, CodingKey {
        case created
        case createdBy = "created_by"
        case author
        case comment
        case emptyLayer = "empty_layer"
    }
}

struct CommitEmpty: Codable, Sendable {}

enum CommitConfig {
    static func mergeEnv(_ base: [String], _ overlay: [String]) -> [String] {
        var result = base
        for item in overlay {
            let key = envKey(item)
            if let index = result.firstIndex(where: { envKey($0) == key }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    static func merge(_ base: [String: String], _ overlay: [String: String]) -> [String: String] {
        var result = base
        for (key, value) in overlay { result[key] = value }
        return result
    }

    static func merge(_ base: [String: CommitEmpty], _ keys: [String]) -> [String: CommitEmpty] {
        var result = base
        for key in keys { result[key] = CommitEmpty() }
        return result
    }

    static func applyContainer(_ container: EngineContainer, to config: inout CommitRuntimeConfig) {
        if !container.user.isEmpty { config.User = container.user }
        if !container.env.isEmpty { config.Env = mergeEnv(config.Env ?? [], container.env) }
        if !container.workingDir.isEmpty { config.WorkingDir = container.workingDir }
        if !container.command.isEmpty {
            config.Cmd = container.command
            config.Entrypoint = []
        }
        if !container.labels.isEmpty {
            config.Labels = merge(config.Labels ?? [:], container.labels)
        }
        if !container.exposedPorts.isEmpty {
            config.ExposedPorts = merge(config.ExposedPorts ?? [:], container.exposedPorts.map(\.dockerKey))
        }
    }

    static func applySpec(_ spec: EngineCommitConfig, to config: inout CommitRuntimeConfig) {
        if let user = spec.user { config.User = user }
        if let env = spec.env { config.Env = mergeEnv(config.Env ?? [], env) }
        if let cmd = spec.cmd { config.Cmd = cmd }
        if let entrypoint = spec.entrypoint { config.Entrypoint = entrypoint }
        if let workingDir = spec.workingDir { config.WorkingDir = workingDir }
        if let labels = spec.labels {
            config.Labels = merge(config.Labels ?? [:], labels)
        }
        if let exposed = spec.exposedPorts {
            config.ExposedPorts = merge(config.ExposedPorts ?? [:], exposed)
        }
        if let volumes = spec.volumes {
            config.Volumes = merge(config.Volumes ?? [:], volumes)
        }
    }

    static func applyInstructions(_ lines: [String], to config: inout CommitRuntimeConfig) throws {
        for raw in lines {
            for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                try applyInstruction(line, to: &config)
            }
        }
    }

    static func applyInstruction(_ raw: String, to config: inout CommitRuntimeConfig) throws {
        let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        guard let space = line.firstIndex(where: { $0.isWhitespace }) else {
            throw EngineError.invalidArgument("invalid Dockerfile instruction: \(raw)")
        }
        let name = String(line[..<space]).uppercased()
        let rest = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        switch name {
        case "ENV":
            config.Env = mergeEnv(config.Env ?? [], try parseAssignments(rest, instruction: "ENV"))
        case "LABEL":
            var labels: [String: String] = [:]
            for item in try parseAssignments(rest, instruction: "LABEL") {
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                labels[parts[0]] = parts[1]
            }
            config.Labels = merge(config.Labels ?? [:], labels)
        case "CMD":
            config.Cmd = try parseCommand(rest)
        case "ENTRYPOINT":
            config.Entrypoint = try parseCommand(rest)
        case "EXPOSE":
            config.ExposedPorts = merge(
                config.ExposedPorts ?? [:],
                rest.split(whereSeparator: \.isWhitespace).map { normalizeExpose(String($0)) }
            )
        case "USER":
            config.User = rest
        case "WORKDIR":
            config.WorkingDir = rest
        case "VOLUME":
            config.Volumes = merge(config.Volumes ?? [:], try parseVolume(rest))
        default:
            throw EngineError.invalidArgument("unsupported Dockerfile instruction: \(name)")
        }
    }

    private static func envKey(_ item: String) -> String {
        String(item.split(separator: "=", maxSplits: 1).first ?? Substring(item))
    }

    private static func stripComment(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return "" }
        return raw
    }

    private static func parseAssignments(_ rest: String, instruction: String) throws -> [String] {
        if rest.contains("=") {
            return try tokenize(rest).map { token in
                if token.contains("=") { return token }
                throw EngineError.invalidArgument("\(instruction) requires KEY=VALUE: \(rest)")
            }
        }
        guard let space = rest.firstIndex(where: { $0.isWhitespace }) else {
            throw EngineError.invalidArgument("\(instruction) requires KEY VALUE: \(rest)")
        }
        let key = String(rest[..<space])
        let value = String(rest[rest.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        return ["\(key)=\(unquote(value))"]
    }

    private static func parseCommand(_ rest: String) throws -> [String] {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                let values = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw EngineError.invalidArgument("invalid JSON exec form: \(rest)")
            }
            return values
        }
        return ["/bin/sh", "-c", trimmed]
    }

    private static func parseVolume(_ rest: String) throws -> [String] {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                let values = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw EngineError.invalidArgument("invalid VOLUME: \(rest)")
            }
            return values
        }
        return trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalizeExpose(_ raw: String) -> String {
        raw.contains("/") ? raw : "\(raw)/tcp"
    }

    private static func tokenize(_ raw: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in raw {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if quote != nil {
            throw EngineError.invalidArgument("unclosed quote in \(raw)")
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquote(_ raw: String) -> String {
        if raw.count >= 2, (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}
