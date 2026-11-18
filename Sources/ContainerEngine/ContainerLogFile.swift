import Foundation

/// `{store}/containers/{id}.log`: one JSON record per line, the Docker `json-file` shape
/// (`{"log":"…\n","stream":"stdout","time":"…"}`), so stdout/stderr and timestamps survive
/// a daemon restart.
enum ContainerLogFile {
    private struct Record: Codable {
        var log: String
        var stream: String
        var time: String
    }

    static func encode(_ entries: [EngineLogEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = Data()
        for entry in entries {
            let record = Record(log: entry.text, stream: entry.stdout ? "stdout" : "stderr", time: ISO8601.string(from: entry.time))
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    /// Records written before this format were raw text; those decode as stdout lines
    /// stamped `fallbackTime`, and `legacy` is set so the caller can rewrite the file.
    static func decode(_ data: Data, fallbackTime: Date) -> (entries: [EngineLogEntry], legacy: Bool) {
        guard !data.isEmpty else { return ([], false) }
        let decoder = JSONDecoder()
        var entries: [EngineLogEntry] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: Data(line)) else {
                return (legacyEntries(String(decoding: data, as: UTF8.self), time: fallbackTime), true)
            }
            entries.append(
                EngineLogEntry(
                    time: ISO8601.parse(record.time) ?? fallbackTime,
                    stdout: record.stream != "stderr",
                    text: record.log
                )
            )
        }
        return (entries, false)
    }

    static func legacyEntries(_ text: String, time: Date) -> [EngineLogEntry] {
        var entries: [EngineLogEntry] = []
        var pending = text
        while let newline = pending.firstIndex(of: "\n") {
            entries.append(EngineLogEntry(time: time, stdout: true, text: String(pending[...newline])))
            pending = String(pending[pending.index(after: newline)...])
        }
        if !pending.isEmpty {
            entries.append(EngineLogEntry(time: time, stdout: true, text: pending))
        }
        return entries
    }

    /// Longest partial line kept back waiting for its newline (Docker uses 16 KiB too).
    static let maxPartialLine = 16 * 1024

    /// Appends `text` to `pending` and returns the complete lines (each ending in `\n`).
    /// An over-long partial line is emitted as-is.
    static func splitLines(_ text: String, pending: inout String) -> [String] {
        pending += text
        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            lines.append(String(pending[...newline]))
            pending = String(pending[pending.index(after: newline)...])
        }
        if pending.utf8.count >= maxPartialLine {
            lines.append(pending)
            pending = ""
        }
        return lines
    }
}
