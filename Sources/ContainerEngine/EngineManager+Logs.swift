import Foundation

/// Older .logs.jsonl files stored pipe fragments; new records mark complete log
/// entries explicitly so partial lines flushed at exit stay separate across boots.
private struct StoredLogChunk: Codable {
    let data: Data
    let stdout: Bool
    let timestamp: Date
    let line: Bool?
    let continuation: Bool?
    let partial: Bool?
}

private struct LogSnapshot: Sendable {
    let records: LogFileSnapshot?
    let legacy: LogFileSnapshot?
    let tty: Bool

    init(_ container: EngineContainer, root: URL) {
        tty = container.tty
        records = LogFileSnapshot(EngineManager.logRecordsURL(id: container.id, root: root))
        legacy = LogFileSnapshot(EngineManager.logURL(id: container.id, root: root))
    }

    func lines(count: Int, stdout: Bool, stderr: Bool, since: Date?, until: Date?) throws -> [EngineIOChunk] {
        guard count > 0 else { return [] }
        let decoder = JSONDecoder()
        var tail = LogTail(count: count)
        func matches(_ chunk: EngineIOChunk) -> Bool {
            guard tty || (chunk.stdout ? stdout : stderr) else { return false }
            guard since != nil || until != nil else { return true }
            // Some pre-json-file raw logs already contain a date prefix. Preserve
            // their bytes on replay, rather than manufacturing a new timestamp.
            let date = chunk.timestamp ?? chunk.data.firstIndex(of: 0x20).flatMap {
                ISO8601.parse(String(decoding: chunk.data[..<$0], as: UTF8.self))
            }
            guard let date else { return true }
            return (since.map { date >= $0 } ?? true) && (until.map { date <= $0 } ?? true)
        }
        try records?.visitReversed { data in
            guard let record = try? decoder.decode(StoredLogChunk.self, from: data) else { return true }
            let chunk = EngineIOChunk(data: record.data, stdout: record.stdout, timestamp: record.timestamp, startsLogLine: record.continuation != true)
            if matches(chunk) {
                if record.line == true {
                    tail.visitLine(chunk, endsLine: record.partial != true)
                } else {
                    tail.visit(chunk)
                }
            }
            return !tail.complete
        }
        if !tail.complete {
            try legacy?.visitReversed(includingDelimiter: true) { data in
                let chunk = ContainerLogFile.decodeLine(data, tty: tty, decoder: decoder)
                if matches(chunk) { tail.visitLine(chunk) }
                return !tail.complete
            }
        }
        return tail.result()
    }
}

extension EngineManager {
    public func containerLogs(_ idOrName: String, follow: Bool = false) async throws
        -> (history: [EngineIOChunk], tty: Bool, live: EngineIOSession?)
    {
        try await tailContainerLogs(idOrName, count: .max, follow: follow, stdout: true, stderr: true, since: nil, until: nil)
    }

    public func tailContainerLogs(
        _ idOrName: String, count: Int, follow: Bool, stdout: Bool, stderr: Bool, since: Date?, until: Date?
    ) async throws -> (history: [EngineIOChunk], tty: Bool, live: EngineIOSession?) {
        let container = try resolveContainer(idOrName)
        let live = follow && container.isActive
            ? subscribeAttach(containerID: container.id, tty: container.tty, stdin: false, kind: .logs)
            : nil
        guard count > 0 else { return ([], container.tty, live) }
        // Capture both file ends in the same actor turn as the subscription.
        let snapshot = LogSnapshot(container, root: containerRoot)
        let reader = Task.detached {
            try snapshot.lines(count: count, stdout: stdout, stderr: stderr, since: since, until: until)
        }
        do {
            let history = try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: {
                reader.cancel()
            }
            return (history, container.tty, live)
        } catch {
            await live?.close()
            throw error
        }
    }

    func logHistory(_ container: EngineContainer) -> [EngineIOChunk] {
        (try? LogSnapshot(container, root: containerRoot).lines(count: .max, stdout: true, stderr: true, since: nil, until: nil)) ?? []
    }

    func appendLogRecord(id: String, chunk: EngineIOChunk, line: Bool = false, endsLine: Bool = true) {
        guard let timestamp = chunk.timestamp else { return }
        let record = StoredLogChunk(
            data: chunk.data, stdout: chunk.stdout, timestamp: timestamp,
            line: line ? true : nil, continuation: chunk.startsLogLine ? nil : true, partial: endsLine ? nil : true
        )
        guard let encoded = try? JSONEncoder().encode(record) else { return }
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
