import Foundation

public enum ISO8601 {
    public static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }

    public static func string(from date: Date, fractional: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Docker filter timestamps: unix seconds, RFC3339, or a Go duration (`24h`, `10m`).
    public static func parseTimestamp(_ raw: String) -> Date? {
        if let seconds = TimeInterval(raw), raw.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let date = parse(raw) {
            return date
        }
        if let duration = parseGoDuration(raw) {
            return Date().addingTimeInterval(-duration)
        }
        return nil
    }

    /// Go `time.ParseDuration` subset: `10s`, `5m`, `1h30m`.
    public static func parseGoDuration(_ raw: String) -> TimeInterval? {
        var text = Substring(raw)
        var sign: TimeInterval = 1
        if text.first == "-" {
            sign = -1
            text.removeFirst()
        } else if text.first == "+" {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        // Longer units first so `ms` is not parsed as `m`.
        let units: [(String, TimeInterval)] = [
            ("ms", 0.001), ("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("μs", 1e-6),
            ("h", 3600), ("m", 60), ("s", 1),
        ]
        var total: TimeInterval = 0
        while !text.isEmpty {
            let digits = text.prefix { $0.isNumber || $0 == "." }
            guard let value = Double(digits) else { return nil }
            text = text.dropFirst(digits.count)
            guard let unit = units.first(where: { text.hasPrefix($0.0) }) else { return nil }
            text = text.dropFirst(unit.0.count)
            total += value * unit.1
        }
        return sign * total
    }
}
