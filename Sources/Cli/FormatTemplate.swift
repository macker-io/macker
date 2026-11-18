import Foundation

/// Docker `--format` subset shared by `images` / `history` / `search` / system commands:
/// optional `table` prefix, `{{.Field}}` (dotted paths for JSON objects), `{{json .}}`,
/// bare `json`, and `\t` / `\n` / `\\` escapes. Pipelines and control flow are not supported.
enum FormatTemplate {
    struct Template {
        enum Part {
            case literal(String)
            case field(String)
            case json(String?)
        }

        let table: Bool
        let parts: [Part]

        /// `table` mode headers: field names uppercased, literals kept, `{{json ...}}` becomes JSON.
        var header: String {
            parts.map { part in
                switch part {
                case .literal(let text): return text
                case .field(let name): return name.uppercased()
                case .json: return "JSON"
                }
            }.joined()
        }
    }

    static func parse(_ raw: String) throws -> Template {
        var text = raw
        var table = false
        if text == "table" || text.hasPrefix("table ") {
            table = true
            text = String(text.dropFirst(5).drop(while: { $0 == " " }))
        } else if text.hasPrefix("table{{") {
            table = true
            text = String(text.dropFirst(5))
        }
        if text.trimmingCharacters(in: .whitespaces) == "json" {
            return Template(table: false, parts: [.json(nil)])
        }

        var parts: [Template.Part] = []
        var literal = ""
        var index = text.startIndex

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("{{") {
                guard let close = text.range(of: "}}", range: index..<text.endIndex) else {
                    throw CLIError.io("unclosed \"{{\" in --format")
                }
                flushLiteral()
                let inner = text[text.index(index, offsetBy: 2)..<close.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                if inner == "json ." || inner == "json(.)" {
                    parts.append(.json(nil))
                } else if let path = jsonFieldPath(inner) {
                    parts.append(.json(path))
                } else if inner.hasPrefix("."), inner.count > 1, !inner.contains(" ") {
                    parts.append(.field(String(inner.dropFirst())))
                } else {
                    throw CLIError.io("unsupported template expression \"\(inner)\" in --format")
                }
                index = close.upperBound
                continue
            }
            let character = text[index]
            if character == "\\", let next = text[text.index(after: index)...].first {
                switch next {
                case "t": literal.append("\t")
                case "n": literal.append("\n")
                case "\\": literal.append("\\")
                default:
                    literal.append(character)
                    literal.append(next)
                }
                index = text.index(index, offsetBy: 2)
                continue
            }
            literal.append(character)
            index = text.index(after: index)
        }
        flushLiteral()
        return Template(table: table, parts: parts)
    }

    /// Bare `table` means the command's default columns, not an empty template.
    static func isBareTable(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines) == "table"
    }

    /// Prints `rows` through the template. Field order in each row is preserved for JSON output.
    static func print(format raw: String, rows: [[(String, String)]]) throws {
        let template = try parse(raw)
        if template.table {
            let split: (String) -> [String] = { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            let rendered = try rows.map { split(try render(template, row: $0)) }
            Table.print(headers: split(template.header), rows: rendered)
            return
        }
        for row in rows {
            Swift.print(try render(template, row: row))
        }
    }

    /// Prints JSON objects (`version` / `info` / `events` / `system df`). `{{.Client.Version}}` walks nested keys.
    static func print(format raw: String, objects: [Any]) throws {
        try print(try parse(raw), objects: objects)
    }

    static func print(_ template: Template, objects: [Any]) throws {
        if template.table {
            let split: (String) -> [String] = { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            let rendered = try objects.map { split(try render(template, object: $0)) }
            Table.print(headers: split(template.header), rows: rendered)
            return
        }
        for object in objects {
            Swift.print(try render(template, object: object))
        }
    }

    static func render(_ template: Template, object: Any) throws -> String {
        try template.parts.map { part in
            switch part {
            case .literal(let text):
                return text
            case .field(let name):
                return stringValue(try lookup(name, in: object))
            case .json(let path):
                let target = try path.map { try lookup($0, in: object) } ?? object
                return jsonCompact(target)
            }
        }.joined()
    }

    private static func jsonFieldPath(_ inner: String) -> String? {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("json .") {
            let path = String(trimmed.dropFirst("json .".count)).trimmingCharacters(in: .whitespaces)
            return !path.isEmpty && !path.contains(" ") ? path : nil
        }
        if trimmed.hasPrefix("json(."), trimmed.hasSuffix(")") {
            let path = String(trimmed.dropFirst("json(.".count).dropLast())
                .trimmingCharacters(in: .whitespaces)
            return !path.isEmpty && !path.contains(" ") ? path : nil
        }
        return nil
    }

    static func lookup(_ path: String, in object: Any) throws -> Any {
        var current = object
        for key in path.split(separator: ".") {
            current = try child(String(key), of: current)
        }
        return current
    }

    private static func child(_ key: String, of object: Any) throws -> Any {
        guard let dict = dictionary(object) else {
            throw CLIError.io("unknown field \"\(key)\" in --format")
        }
        if let value = dict[key] { return value }
        if let pair = dict.first(where: { $0.key.lowercased() == key.lowercased() }) {
            return pair.value
        }
        throw CLIError.io("unknown field \"\(key)\" in --format")
    }

    private static func dictionary(_ object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] { return dict }
        guard let dict = object as? NSDictionary else { return nil }
        var result: [String: Any] = [:]
        result.reserveCapacity(dict.count)
        for (key, value) in dict {
            if let key = key as? String {
                result[key] = value
            }
        }
        return result
    }

    private static func stringValue(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let text = value as? String { return text }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return jsonCompact(value)
    }

    static func jsonCompact(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let text = value as? String { return "\"\(escape(text))\"" }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func render(_ template: Template, row: [(String, String)]) throws -> String {
        try template.parts.map { part in
            switch part {
            case .literal(let text):
                return text
            case .field(let name):
                guard let value = row.first(where: { $0.0 == name })?.1 else {
                    throw CLIError.io("unknown field \"\(name)\" in --format")
                }
                return value
            case .json(let path):
                guard let path else { return jsonLine(row) }
                guard let value = row.first(where: { $0.0.caseInsensitiveCompare(path) == .orderedSame })?.1 else {
                    throw CLIError.io("unknown field \"\(path)\" in --format")
                }
                return jsonCompact(value)
            }
        }.joined()
    }

    static func jsonLine(_ fields: [(String, String)]) -> String {
        let body = fields.map { "\"\(escape($0.0))\":\"\(escape($0.1))\"" }.joined(separator: ",")
        return "{\(body)}"
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }
}
