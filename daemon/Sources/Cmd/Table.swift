import Foundation

enum Table {
    static func print(headers: [String], rows: [[String]]) {
        let headers = headers.map(oneLine)
        let rows = rows.map { $0.map(oneLine) }
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func line(_ columns: [String]) {
            let padded = zip(columns, widths).map { cell, width in
                cell.padding(toLength: width, withPad: " ", startingAt: 0)
            }
            Swift.print(padded.joined(separator: "   "))
        }
        line(headers)
        for row in rows {
            line(row)
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        let kilobytes = Double(bytes) / 1024
        if kilobytes < 1024 { return String(format: "%.1fkB", kilobytes) }
        return String(format: "%.1fMB", kilobytes / 1024)
    }

    static func shortID(_ id: String) -> String {
        let hex = id.hasPrefix("sha256:") ? String(id.dropFirst("sha256:".count)) : id
        return String(hex.prefix(12))
    }
}
