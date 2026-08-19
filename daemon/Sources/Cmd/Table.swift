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
        if id == "<missing>" { return id }
        let hex = id.hasPrefix("sha256:") ? String(id.dropFirst("sha256:".count)) : id
        return String(hex.prefix(12))
    }

    static func createdBy(_ text: String, truncating: Bool) -> String {
        let cleaned = text.replacingOccurrences(of: "\t", with: " ")
        guard truncating, cleaned.count > 45 else { return cleaned }
        return String(cleaned.prefix(42)) + "..."
    }

    /// Docker `--format .CreatedAt`: Go's default time rendering in UTC.
    static func createdAt(_ unix: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss '+0000 UTC'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Docker ellipsis truncation: keep `limit - 3` chars and append "...".
    static func ellipsis(_ text: String, _ limit: Int = 45) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 3)) + "..."
    }

    /// Docker `units.HumanDuration` plus `" ago"`.
    static func timeAgo(_ unix: Int64, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - Int(unix))
        if seconds < 1 { return "Less than a second ago" }
        if seconds == 1 { return "1 second ago" }
        if seconds < 60 { return "\(seconds) seconds ago" }
        let minutes = seconds / 60
        if minutes == 1 { return "About a minute ago" }
        if minutes < 60 { return "\(minutes) minutes ago" }
        let hours = Int((Double(seconds) / 3600.0).rounded())
        if hours == 1 { return "About an hour ago" }
        if hours < 48 { return "\(hours) hours ago" }
        if hours < 24 * 7 * 2 { return "\(hours / 24) days ago" }
        if hours < 24 * 30 * 2 { return "\(hours / 24 / 7) weeks ago" }
        if hours < 24 * 365 * 2 { return "\(hours / 24 / 30) months ago" }
        return "\(hours / 24 / 365) years ago"
    }
}
