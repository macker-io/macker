import Foundation

/// `.dockerignore` matcher. Patterns are relative to the context root, `!` re-includes,
/// and a matching directory excludes everything under it. Later rules win.
public struct DockerIgnore: Sendable {
    struct Rule: Sendable {
        var regex: NSRegularExpression
        var negated: Bool
    }

    private let rules: [Rule]

    public init(_ text: String) {
        var rules: [Rule] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard let pattern = Self.normalize(line) else { continue }
            guard let regex = try? NSRegularExpression(pattern: "^\(Self.regexBody(pattern))$") else { continue }
            rules.append(Rule(regex: regex, negated: negated))
        }
        self.rules = rules
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// `path` is relative to the context root, slash-separated, without a trailing slash.
    public func excludes(_ path: String) -> Bool {
        let candidates = Self.selfAndParents(path)
        var excluded = false
        for rule in rules {
            guard candidates.contains(where: { rule.regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) else {
                continue
            }
            excluded = !rule.negated
        }
        return excluded
    }

    /// A negation can re-include a file under an excluded directory, so the context
    /// walk may not prune excluded directories when any rule re-includes.
    public var hasNegations: Bool {
        rules.contains(where: \.negated)
    }

    static func selfAndParents(_ path: String) -> [String] {
        var parts = path.split(separator: "/").map(String.init)
        var result: [String] = []
        while !parts.isEmpty {
            result.append(parts.joined(separator: "/"))
            parts.removeLast()
        }
        return result
    }

    static func normalize(_ raw: String) -> String? {
        var pattern = raw.replacingOccurrences(of: "\\", with: "/")
        while pattern.hasPrefix("./") { pattern = String(pattern.dropFirst(2)) }
        while pattern.hasPrefix("/") { pattern = String(pattern.dropFirst()) }
        while pattern.count > 1, pattern.hasSuffix("/") { pattern = String(pattern.dropLast()) }
        if pattern.isEmpty || pattern == "." || pattern == "/" { return nil }
        return pattern
    }

    /// Go `filepath.Match` plus `**`, translated to NSRegularExpression syntax.
    static func regexBody(_ pattern: String) -> String {
        var body = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "*":
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let after = pattern.index(after: next)
                    if after < pattern.endIndex, pattern[after] == "/" {
                        body += "(?:[^/]+/)*"
                        index = pattern.index(after: after)
                        continue
                    }
                    body += ".*"
                    index = after
                    continue
                }
                body += "[^/]*"
                index = next
            case "?":
                body += "[^/]"
                index = pattern.index(after: index)
            case "[":
                guard let closing = pattern[pattern.index(after: index)...].firstIndex(of: "]") else {
                    body += "\\["
                    index = pattern.index(after: index)
                    continue
                }
                body += String(pattern[index...closing])
                index = pattern.index(after: closing)
            default:
                body += NSRegularExpression.escapedPattern(for: String(character))
                index = pattern.index(after: index)
            }
        }
        return body
    }
}
