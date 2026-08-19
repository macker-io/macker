import Foundation

/// Docker `--format` subset shared by `images` / `history` / `search`:
/// optional `table` prefix, `{{.Field}}` placeholders, `{{json .}}`, bare `json`,
/// and `\t` / `\n` / `\\` escapes. Pipelines and control flow are not supported.
enum FormatTemplate {
    struct Template {
        enum Part {
            case literal(String)
            case field(String)
            case json
        }

        let table: Bool
        let parts: [Part]

        /// `table` mode headers: field names uppercased, literals kept, `{{json .}}` becomes JSON.
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
            return Template(table: false, parts: [.json])
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
                    parts.append(.json)
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

    private static func render(_ template: Template, row: [(String, String)]) throws -> String {
        try template.parts.map { part in
            switch part {
            case .literal(let text):
                return text
            case .field(let name):
                guard let value = row.first(where: { $0.0 == name })?.1 else {
                    throw CLIError.io("unknown field \"\(name)\" in --format")
                }
                return value
            case .json:
                return jsonLine(row)
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
