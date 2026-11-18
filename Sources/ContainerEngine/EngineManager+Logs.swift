import Foundation

/// Persist output with its original stream and capture time. Older plain-text logs
/// remain readable, but their original stream and timestamp cannot be recovered.
private struct StoredLogChunk: Codable {
    let data: Data
    let stdout: Bool
    let timestamp: Date
}

extension EngineManager {
    public func containerLogs(_ idOrName: String, follow: Bool = false) throws
        -> (history: [EngineIOChunk], tty: Bool, live: EngineIOSession?)
    {
        let container = try resolveContainer(idOrName)
        let history = logHistory(container)
        let live = follow && container.isActive
            ? subscribeAttach(containerID: container.id, tty: container.tty, stdin: false, kind: .logs)
            : nil
        return (history, container.tty, live)
    }

    public func tailContainerLogs(
        _ idOrName: String, count: Int, follow: Bool, stdout: Bool, stderr: Bool, since: Date?, until: Date?
    ) async throws -> (history: [EngineIOChunk], tty: Bool, live: EngineIOSession?) {
        let container = try resolveContainer(idOrName)
        let tty = container.tty
        let live = follow && container.isActive
            ? subscribeAttach(containerID: container.id, tty: tty, stdin: false, kind: .logs)
            : nil
        guard count > 0 else { return ([], tty, live) }

        let records = LogFileSnapshot(Self.logRecordsURL(id: container.id, root: containerRoot))
        let legacy = LogFileSnapshot(Self.logURL(id: container.id, root: containerRoot))
        // Open files and subscribe in the same actor turn; do disk scans off the actor.
        let reader = Task.detached {
            var tail = LogTail(count: count)
            let decoder = JSONDecoder()
            try records?.visitReversed { data in
                guard let record = try? decoder.decode(StoredLogChunk.self, from: data),
                    tty || (record.stdout ? stdout : stderr),
                    since.map({ record.timestamp >= $0 }) ?? true,
                    until.map({ record.timestamp <= $0 }) ?? true
                else { return true }
                tail.visit(EngineIOChunk(data: record.data, stdout: record.stdout, timestamp: record.timestamp))
                return !tail.complete
            }
            if !tail.complete, tty || stdout, let legacy, legacy.end > 0 {
                try Task.checkCancellation()
                let raw = String(decoding: try legacy.read(), as: UTF8.self)
                let cooked = tty ? TTYSession.cook(raw) : raw
                let text = Self.filterLegacyLogs(cooked, since: since, until: until)
                tail.visit(EngineIOChunk(data: Data(text.utf8), stdout: true))
            }
            return tail.result()
        }
        do {
            let history = try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: {
                reader.cancel()
            }
            return (history, tty, live)
        } catch {
            await live?.close()
            throw error
        }
    }

    private static func filterLegacyLogs(_ text: String, since: Date?, until: Date?) -> String {
        guard since != nil || until != nil else { return text }
        var lines = text.components(separatedBy: "\n")
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        let filtered = lines.filter { line in
            guard let token = line.split(separator: " ", maxSplits: 1).first,
                let date = ISO8601.parse(String(token))
            else { return true }
            return (since.map { date >= $0 } ?? true) && (until.map { date <= $0 } ?? true)
        }
        return filtered.joined(separator: "\n") + (trailingNewline && !filtered.isEmpty ? "\n" : "")
    }

    func logHistory(_ container: EngineContainer) -> [EngineIOChunk] {
        var chunks: [EngineIOChunk] = []
        if let raw = try? String(contentsOf: Self.logURL(id: container.id, root: containerRoot), encoding: .utf8),
            !raw.isEmpty
        {
            let text = container.tty ? TTYSession.cook(raw) : raw
            chunks.append(EngineIOChunk(data: Data(text.utf8), stdout: true))
        }
        if let data = try? Data(contentsOf: Self.logRecordsURL(id: container.id, root: containerRoot)) {
            let decoder = JSONDecoder()
            for line in data.split(separator: 0x0a) {
                guard let record = try? decoder.decode(StoredLogChunk.self, from: line) else { continue }
                chunks.append(EngineIOChunk(data: record.data, stdout: record.stdout, timestamp: record.timestamp))
            }
        }
        return chunks
    }

    func appendLogRecord(id: String, chunk: EngineIOChunk) {
        guard let timestamp = chunk.timestamp,
            let encoded = try? JSONEncoder().encode(StoredLogChunk(data: chunk.data, stdout: chunk.stdout, timestamp: timestamp))
        else { return }
        // Start with a separator so a torn final record cannot corrupt the next append.
        var data = Data([0x0a])
        data.append(encoded)
        let url = Self.logRecordsURL(id: id, root: containerRoot)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }

    static func logURL(id: String, root: URL) -> URL {
        root.appendingPathComponent("\(id).log")
    }

    static func logRecordsURL(id: String, root: URL) -> URL {
        root.appendingPathComponent("\(id).logs.jsonl")
    }
}
