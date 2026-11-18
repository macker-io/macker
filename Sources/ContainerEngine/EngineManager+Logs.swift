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
