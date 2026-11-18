import Foundation

/// Compatibility reader for the previous {id}.log formats: Docker json-file records
/// and, before those, plain stdout. New writes use byte-preserving .logs.jsonl records.
enum ContainerLogFile {
    private struct Record: Decodable {
        let log: String
        let stream: String
        let time: String
    }

    static func decodeLine(_ line: Data, tty: Bool, decoder: JSONDecoder) -> EngineIOChunk {
        if line.first == 0x7b, let record = try? decoder.decode(Record.self, from: line),
            ["stdout", "stderr"].contains(record.stream), let time = ISO8601.parse(record.time)
        {
            return EngineIOChunk(data: Data(record.log.utf8), stdout: record.stream == "stdout", timestamp: time)
        }
        return EngineIOChunk(data: tty ? TTYSession.cookBytes(line) : line, stdout: true)
    }
}
