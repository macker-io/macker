import Foundation

/// A captured end offset keeps history disjoint from output arriving after a follow subscription.
struct LogFileSnapshot: Sendable {
    let handle: FileHandle
    let end: UInt64

    init?(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url), let end = try? handle.seekToEnd() else { return nil }
        self.handle = handle
        self.end = end
    }

    func read() throws -> Data {
        try handle.seek(toOffset: 0)
        return try handle.read(upToCount: Int(end)) ?? Data()
    }

    /// Visit JSONL records from newest to oldest, holding one block and at most one split record.
    func visitReversed(_ visit: (Data) -> Bool) throws {
        var cursor = end
        var fragments: [Data] = []
        while cursor > 0 {
            try Task.checkCancellation()
            let count = Int(min(cursor, 64 * 1024))
            cursor -= UInt64(count)
            try handle.seek(toOffset: cursor)
            guard let block = try handle.read(upToCount: count), block.count == count else { return }
            let parts = block.split(separator: 0x0a, omittingEmptySubsequences: false)
            for part in parts.dropFirst().reversed() {
                let record = Self.join(part, with: fragments)
                fragments.removeAll(keepingCapacity: true)
                if !record.isEmpty, !visit(record) { return }
            }
            if let first = parts.first, !first.isEmpty { fragments.append(first) }
        }
        let record = Self.join(Data(), with: fragments)
        if !record.isEmpty { _ = visit(record) }
    }

    private static func join(_ prefix: Data, with fragments: [Data]) -> Data {
        var result = prefix
        for fragment in fragments.reversed() { result.append(fragment) }
        return result
    }
}

/// Reserve slots by line completion (or the last bytes of an unterminated line), then walk
/// back to each line's start. A fragment from the other stream cannot complete that line.
struct LogTail {
    private struct Line {
        let index: Int
        var fragments: [Data] = []
        var timestamp: Date?
    }

    let count: Int
    private var slots: [EngineIOChunk?] = []
    private var open: [Bool: Line] = [:]
    private var seen: Set<Bool> = []

    init(count: Int) { self.count = count }

    var complete: Bool { slots.count == count && open.isEmpty }

    mutating func visit(_ chunk: EngineIOChunk) {
        guard !chunk.data.isEmpty else { return }
        let stdout = chunk.stdout
        let first = seen.insert(stdout).inserted
        var end = chunk.data.endIndex
        while let newline = chunk.data[..<end].lastIndex(of: 0x0a) {
            let start = chunk.data.index(after: newline)
            if first, end == chunk.data.endIndex, start < end { begin(stdout) }
            append(chunk.data[start..<end], stdout: stdout, timestamp: chunk.timestamp)
            finish(stdout)
            begin(stdout)
            append(Data([0x0a]), stdout: stdout, timestamp: chunk.timestamp)
            end = newline
            if complete { return }
        }
        if first, end == chunk.data.endIndex { begin(stdout) }
        append(chunk.data[..<end], stdout: stdout, timestamp: chunk.timestamp)
    }

    mutating func result() -> [EngineIOChunk] {
        finish(true)
        finish(false)
        return slots.reversed().compactMap { $0 }
    }

    private mutating func begin(_ stdout: Bool) {
        guard slots.count < count else { return }
        open[stdout] = Line(index: slots.count)
        slots.append(nil)
    }

    private mutating func append(_ data: Data, stdout: Bool, timestamp: Date?) {
        guard !data.isEmpty, open[stdout] != nil else { return }
        open[stdout]?.fragments.append(data)
        open[stdout]?.timestamp = timestamp
    }

    private mutating func finish(_ stdout: Bool) {
        guard let line = open.removeValue(forKey: stdout) else { return }
        var data = Data()
        for fragment in line.fragments.reversed() { data.append(fragment) }
        slots[line.index] = EngineIOChunk(data: data, stdout: stdout, timestamp: line.timestamp)
    }
}
