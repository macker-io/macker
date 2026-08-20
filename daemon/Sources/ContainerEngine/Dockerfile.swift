import Foundation

/// One `--flag=value` / `--flag` pair in front of an instruction's arguments.
public struct DockerfileFlags: Sendable, Equatable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(name: String) -> String? { values[name] }
    public var isEmpty: Bool { values.isEmpty }
    public var names: [String] { values.keys.sorted() }
}

public struct DockerfileInstruction: Sendable, Equatable {
    /// Uppercased instruction name (`RUN`, `COPY`, …).
    public var name: String
    /// Everything after the name and its flags, whitespace-trimmed.
    public var arguments: String
    public var flags: DockerfileFlags
    /// Line number of the instruction in the Dockerfile, for error messages.
    public var line: Int

    public init(name: String, arguments: String, flags: DockerfileFlags = DockerfileFlags(), line: Int = 0) {
        self.name = name
        self.arguments = arguments
        self.flags = flags
        self.line = line
    }

    /// Canonical single-line form. Feeds `docker history` and the layer cache key.
    public var source: String {
        var parts = [name]
        for flag in flags.names {
            let value = flags[flag] ?? ""
            parts.append(value.isEmpty ? "--\(flag)" : "--\(flag)=\(value)")
        }
        if !arguments.isEmpty {
            parts.append(arguments)
        }
        return parts.joined(separator: " ")
    }
}

public struct DockerfileArg: Sendable, Equatable {
    public var name: String
    public var defaultValue: String?

    public init(name: String, defaultValue: String? = nil) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public struct DockerfileStage: Sendable, Equatable {
    public var index: Int
    /// Lowercased `AS` name, when the stage has one.
    public var name: String?
    /// `FROM` argument, before ARG expansion.
    public var base: String
    public var platform: String?
    public var instructions: [DockerfileInstruction]

    public init(
        index: Int,
        name: String? = nil,
        base: String,
        platform: String? = nil,
        instructions: [DockerfileInstruction] = []
    ) {
        self.index = index
        self.name = name
        self.base = base
        self.platform = platform
        self.instructions = instructions
    }
}

/// A parsed Dockerfile: global `ARG`s plus one entry per `FROM`.
public struct Dockerfile: Sendable, Equatable {
    public var globalArgs: [DockerfileArg]
    public var stages: [DockerfileStage]

    /// Instructions that change the image config only, never the filesystem.
    static let metadataInstructions: Set<String> = [
        "ENV", "LABEL", "CMD", "ENTRYPOINT", "EXPOSE", "USER", "WORKDIR", "VOLUME",
        "STOPSIGNAL", "SHELL", "ARG", "MAINTAINER", "HEALTHCHECK",
    ]

    static let supportedInstructions: Set<String> = metadataInstructions.union(["FROM", "RUN", "COPY", "ADD"])

    /// Instructions whose arguments are expanded with build args / ENV at build time.
    /// `RUN`, `CMD` and `ENTRYPOINT` are left to the guest shell, matching Docker.
    static let expandedInstructions: Set<String> = [
        "ADD", "COPY", "ENV", "EXPOSE", "FROM", "LABEL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR", "ARG", "HEALTHCHECK",
    ]

    /// Only these read leading `--flag` tokens; elsewhere `--` is part of the command.
    static let flaggedInstructions: Set<String> = ["FROM", "COPY", "ADD", "RUN", "HEALTHCHECK"]

    public init(globalArgs: [DockerfileArg] = [], stages: [DockerfileStage] = []) {
        self.globalArgs = globalArgs
        self.stages = stages
    }

    public static func parse(_ text: String) throws -> Dockerfile {
        let escape = escapeCharacter(in: text)
        var globalArgs: [DockerfileArg] = []
        var stages: [DockerfileStage] = []

        for logical in logicalLines(text, escape: escape) {
            let instruction = try parseInstruction(logical)
            guard supportedInstructions.contains(instruction.name) else {
                throw EngineError.invalidArgument(
                    "Dockerfile line \(instruction.line): unsupported instruction \(instruction.name)"
                )
            }
            if instruction.name == "FROM" {
                stages.append(try parseStage(instruction, index: stages.count))
                continue
            }
            guard !stages.isEmpty else {
                guard instruction.name == "ARG" else {
                    throw EngineError.invalidArgument(
                        "Dockerfile line \(instruction.line): \(instruction.name) before any FROM instruction"
                    )
                }
                globalArgs.append(try parseArg(instruction))
                continue
            }
            stages[stages.count - 1].instructions.append(instruction)
        }

        guard !stages.isEmpty else {
            throw EngineError.invalidArgument("Dockerfile contains no FROM instruction")
        }
        return Dockerfile(globalArgs: globalArgs, stages: stages)
    }

    /// Features the classic builder will never grow. Used to fail fast (and later
    /// to dispatch to the BuildKit backend).
    static func buildKitSyntax(in text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                if body.hasPrefix("syntax") {
                    let rest = body.dropFirst("syntax".count).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("=") { return "# syntax=" }
                }
                continue
            }
            let upper = line.uppercased()
            if (upper.hasPrefix("RUN") || upper.hasPrefix("COPY") || upper.hasPrefix("ADD")), line.contains("<<") {
                return "heredoc"
            }
        }
        return nil
    }

    var buildKitInstruction: String? {
        for stage in stages {
            for instruction in stage.instructions {
                if instruction.name == "RUN", !instruction.flags.isEmpty {
                    return "RUN --\(instruction.flags.names.joined(separator: " --"))"
                }
                if instruction.name == "COPY" || instruction.name == "ADD" {
                    let extra = instruction.flags.names.filter { !["from", "chown", "chmod"].contains($0) }
                    if let name = extra.first {
                        return "\(instruction.name) --\(name)"
                    }
                }
            }
        }
        return nil
    }

    /// `--target` lookup: stage name first (case-insensitive), then a stage index.
    public func stage(named target: String) -> DockerfileStage? {
        let needle = target.lowercased()
        if let match = stages.first(where: { $0.name == needle }) {
            return match
        }
        if let index = Int(needle), stages.indices.contains(index) {
            return stages[index]
        }
        return nil
    }

    static func parseArg(_ instruction: DockerfileInstruction) throws -> DockerfileArg {
        let raw = instruction.arguments.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            throw EngineError.invalidArgument("Dockerfile line \(instruction.line): ARG requires a name")
        }
        guard let equals = raw.firstIndex(of: "=") else {
            return DockerfileArg(name: raw)
        }
        let name = String(raw[..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: equals)...])
        return DockerfileArg(name: name, defaultValue: Shellwords.unquote(value))
    }

    private static func parseStage(_ instruction: DockerfileInstruction, index: Int) throws -> DockerfileStage {
        let tokens = try Shellwords.split(instruction.arguments)
        guard let base = tokens.first, !base.isEmpty else {
            throw EngineError.invalidArgument("Dockerfile line \(instruction.line): FROM requires an image")
        }
        var name: String?
        if tokens.count >= 3, tokens[1].uppercased() == "AS" {
            name = tokens[2].lowercased()
        } else if tokens.count != 1 {
            throw EngineError.invalidArgument("Dockerfile line \(instruction.line): FROM \(instruction.arguments) is not valid")
        }
        return DockerfileStage(
            index: index,
            name: name,
            base: base,
            platform: instruction.flags["platform"],
            instructions: []
        )
    }

    private static func parseInstruction(_ logical: LogicalLine) throws -> DockerfileInstruction {
        let text = logical.text.trimmingCharacters(in: .whitespaces)
        guard let space = text.firstIndex(where: { $0.isWhitespace }) else {
            throw EngineError.invalidArgument("Dockerfile line \(logical.line): \(text) has no arguments")
        }
        let name = String(text[..<space]).uppercased()
        var rest = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        var flags: [String: String] = [:]
        while flaggedInstructions.contains(name), rest.hasPrefix("--") {
            guard let token = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) else { break }
            let body = String(token.dropFirst(2))
            if let equals = body.firstIndex(of: "=") {
                flags[String(body[..<equals])] = Shellwords.unquote(String(body[body.index(after: equals)...]))
            } else {
                flags[body] = ""
            }
            rest = String(rest.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !rest.isEmpty else {
            throw EngineError.invalidArgument("Dockerfile line \(logical.line): \(name) requires arguments")
        }
        return DockerfileInstruction(name: name, arguments: rest, flags: DockerfileFlags(flags), line: logical.line)
    }

    /// `# escape=\`` on the first non-empty line switches the continuation character.
    static func escapeCharacter(in text: String) -> Character {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("#") else { return "\\" }
            let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
            if directive.hasPrefix("escape=") {
                let value = directive.dropFirst("escape=".count).trimmingCharacters(in: .whitespaces)
                if value == "`" { return "`" }
                return "\\"
            }
        }
        return "\\"
    }

    struct LogicalLine {
        var text: String
        var line: Int
    }

    /// Joins continuations, drops comments and blank lines. Comments inside a
    /// continuation are skipped without breaking the instruction, like Docker.
    static func logicalLines(_ text: String, escape: Character = "\\") -> [LogicalLine] {
        var result: [LogicalLine] = []
        var pending: String?
        var pendingLine = 0
        for (offset, raw) in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        {
            let number = offset + 1
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if pending == nil {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            } else if trimmed.hasPrefix("#") {
                continue
            }
            let continues = trimmed.last == escape
            let body = continues
                ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                : trimmed
            if pending == nil {
                pending = body
                pendingLine = number
            } else {
                pending! += pending!.isEmpty || body.isEmpty ? body : " " + body
            }
            if !continues {
                if let text = pending, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(LogicalLine(text: text.trimmingCharacters(in: .whitespaces), line: pendingLine))
                }
                pending = nil
            }
        }
        if let text = pending, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(LogicalLine(text: text.trimmingCharacters(in: .whitespaces), line: pendingLine))
        }
        return result
    }
}

/// Quote handling and `$VAR` expansion shared by the Dockerfile parser and the builder.
public enum Shellwords {
    /// Whitespace split that honours single and double quotes.
    public static func split(_ raw: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            index = raw.index(after: index)
            if character == "\\", let next = index < raw.endIndex ? raw[index] : nil, quote != "'" {
                current.append(next)
                started = true
                index = raw.index(after: index)
                continue
            }
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
                started = true
                continue
            }
            if character.isWhitespace {
                if started {
                    tokens.append(current)
                    current = ""
                    started = false
                }
                continue
            }
            current.append(character)
            started = true
        }
        if quote != nil {
            throw EngineError.invalidArgument("unclosed quote in \(raw)")
        }
        if started {
            tokens.append(current)
        }
        return tokens
    }

    /// JSON array form (`["a","b"]`), else the shell form wrapped in `shell`.
    public static func command(_ raw: String, shell: [String]) throws -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                let values = try? JSONDecoder().decode([String].self, from: data)
            else {
                throw EngineError.invalidArgument("invalid JSON exec form: \(raw)")
            }
            return values
        }
        return shell + [trimmed]
    }

    public static func isJSONForm(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    public static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// `$NAME`, `${NAME}`, `${NAME:-default}`, `${NAME:+alternate}`. `\$` stays literal.
    public static func expand(_ raw: String, variables: [String: String]) -> String {
        var result = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\\", raw.index(after: index) < raw.endIndex, raw[raw.index(after: index)] == "$" {
                result.append("$")
                index = raw.index(index, offsetBy: 2)
                continue
            }
            guard character == "$" else {
                result.append(character)
                index = raw.index(after: index)
                continue
            }
            var cursor = raw.index(after: index)
            guard cursor < raw.endIndex else {
                result.append("$")
                break
            }
            if raw[cursor] == "{" {
                cursor = raw.index(after: cursor)
                guard let closing = raw[cursor...].firstIndex(of: "}") else {
                    result.append("$")
                    index = raw.index(after: index)
                    continue
                }
                result.append(brace(String(raw[cursor..<closing]), variables: variables))
                index = raw.index(after: closing)
                continue
            }
            let name = raw[cursor...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if name.isEmpty {
                result.append("$")
                index = cursor
                continue
            }
            result.append(variables[String(name)] ?? "")
            index = raw.index(cursor, offsetBy: name.count)
        }
        return result
    }

    private static func brace(_ body: String, variables: [String: String]) -> String {
        if let range = body.range(of: ":-") {
            let name = String(body[..<range.lowerBound])
            let fallback = String(body[range.upperBound...])
            let value = variables[name] ?? ""
            return value.isEmpty ? expand(fallback, variables: variables) : value
        }
        if let range = body.range(of: ":+") {
            let name = String(body[..<range.lowerBound])
            let alternate = String(body[range.upperBound...])
            let value = variables[name] ?? ""
            return value.isEmpty ? "" : expand(alternate, variables: variables)
        }
        return variables[body] ?? ""
    }
}
