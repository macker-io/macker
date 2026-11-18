import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct LogHistoryTests {
    @Test func recordsSurviveReloadAndKeepTheirStreams() async throws {
        try await TemporaryDirectory.with("macker-log-history") { store in
            let engine = try EngineManager(storePath: store)
            try await RouterTestSupport.importTagged(engine, repo: "log-test")
            let id = try await RouterTestSupport.createContainer(Router(engine: engine), image: "log-test")
            let root = store.appendingPathComponent("containers")
            try Data("legacy\n".utf8).write(to: EngineManager.logURL(id: id, root: root))
            await engine.appendOutput(id: id, data: Data("output\n".utf8), stdout: true)
            await engine.appendOutput(id: id, data: Data("error\n".utf8), stdout: false)

            let restored = try EngineManager(storePath: store)
            let router = Router(engine: restored)
            let request = try RouterTestSupport.request(
                "GET", "/containers/\(id)/logs", query: ["stderr": "1", "stdout": "0"]
            )
            let response = await router.handle(request)
            #expect(response.status == 200)
            var buffer = RouterTestSupport.data(response)
            let frames = DockerStdio.pullFrames(&buffer).frames
            #expect(frames.map(\.stream) == [2])
            #expect(frames.map { String(decoding: $0.payload, as: UTF8.self) } == ["error\n"])
            let history = try await restored.containerLogs(id).history
            #expect(history.count == 3)
            #expect(history.first?.timestamp == nil)
            #expect(history.last?.timestamp != nil)
        }
    }

    @Test func finiteTailStopsBeforeOldBlocksAndRespectsSnapshot() throws {
        try TemporaryDirectory.with("macker-log-tail-blocks") { root in
            let url = root.appendingPathComponent("logs")
            let newest = String(repeating: "x", count: 70_000)
            let old = String(repeating: "old record\n", count: 30_000)
            try Data((old + newest).utf8).write(to: url)
            let snapshot = try #require(LogFileSnapshot(url))
            let writer = try FileHandle(forWritingTo: url)
            defer { try? writer.close() }
            _ = try writer.seekToEnd()
            try writer.write(contentsOf: Data("\nnew live record".utf8))

            var visited: [Data] = []
            try snapshot.visitReversed {
                visited.append($0)
                return false
            }
            #expect(visited == [Data(newest.utf8)])
            #expect(try snapshot.handle.offset() > 64 * 1024)
        }
    }

    @Test func finiteTailFiltersAndReassemblesAcrossStreams() async throws {
        try await withEngine { engine in
            try await RouterTestSupport.importTagged(engine, repo: "tail-test")
            let router = Router(engine: engine)
            let id = try await RouterTestSupport.createContainer(router, image: "tail-test")
            let root = await engine.containerRoot
            try Data("legacy\n".utf8).write(to: EngineManager.logURL(id: id, root: root))
            let time = Date(timeIntervalSince1970: 1_700_000_000)
            for (text, stdout, offset) in [
                ("old\n", false, -10), ("er", false, 0), ("out\n", true, 1),
                ("ror\nlast", false, 2), (" discarded\n", false, 10),
            ] {
                await engine.appendLogRecord(id: id, chunk: EngineIOChunk(
                    data: Data(text.utf8), stdout: stdout, timestamp: time.addingTimeInterval(Double(offset))
                ))
            }

            func fetch(_ query: [String: String]) async throws -> [(UInt8, String)] {
                let request = try RouterTestSupport.request("GET", "/containers/\(id)/logs", query: query)
                let response = await router.handle(request)
                #expect(response.status == 200)
                var data = RouterTestSupport.data(response)
                return DockerStdio.pullFrames(&data).frames.map { ($0.stream, String(decoding: $0.payload, as: UTF8.self)) }
            }
            let filtered = try await fetch([
                "tail": "2", "stderr": "1", "timestamps": "1",
                "since": ISO8601.string(from: time), "until": ISO8601.string(from: time.addingTimeInterval(2)),
            ])
            #expect(filtered.map { $0.0 } == [2, 2])
            #expect(filtered.map { $0.1 } == [
                "\(ISO8601.string(from: time)) error\n",
                "\(ISO8601.string(from: time.addingTimeInterval(2))) last",
            ])
            let combined = try await fetch(["tail": "2", "stdout": "1", "stderr": "1"])
            #expect(combined.map { $0.0 } == [2, 2])
            #expect(combined.map { $0.1 } == ["error\n", "last discarded\n"])
            let legacy = try await fetch(["tail": "2", "stdout": "1"])
            #expect(legacy.map { $0.1 } == ["legacy\n", "out\n"])
            #expect(try await fetch(["tail": "0", "stdout": "1", "stderr": "1"]).isEmpty)
        }
    }

    @Test func timestampedTailMatchesHistoryWithUnterminatedStreams() async throws {
        try await withEngine { engine in
            try await RouterTestSupport.importTagged(engine, repo: "tail-order")
            let router = Router(engine: engine)
            let time = Date(timeIntervalSince1970: 1_700_000_000)
            for records in [
                [("stdout", true), ("stderr\n", false)],
                [("out", true), ("err", false), ("put", true)],
                [("out", true), ("error\n", false), ("put\nlast", true)],
            ] {
                let id = try await RouterTestSupport.createContainer(router, image: "tail-order")
                for (text, stdout) in records {
                    await engine.appendLogRecord(id: id, chunk: EngineIOChunk(
                        data: Data(text.utf8), stdout: stdout, timestamp: time
                    ))
                }

                func replay(tail: String) async throws -> [(stream: UInt8, payload: Data)] {
                    let request = try RouterTestSupport.request(
                        "GET", "/containers/\(id)/logs",
                        query: ["stdout": "1", "stderr": "1", "timestamps": "1", "tail": tail]
                    )
                    let response = await router.handle(request)
                    #expect(response.status == 200)
                    var data = RouterTestSupport.data(response)
                    return DockerStdio.pullFrames(&data).frames
                }

                let history = try await replay(tail: "all")
                #expect(history.count >= 2)
                for count in 1...records.count {
                    let tail = try await replay(tail: String(count))
                    let expected = history.suffix(count)
                    #expect(tail.map(\.stream) == expected.map(\.stream))
                    #expect(tail.map(\.payload) == expected.map(\.payload))
                }
            }
        }
    }

    @Test func historyJoinsPipeFragmentsAndUsesCaptureTime() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_010)
        let chunks = [
            EngineIOChunk(data: Data("old\n".utf8), stdout: true, timestamp: older),
            EngineIOChunk(data: Data("er".utf8), stdout: false, timestamp: newer),
            EngineIOChunk(data: Data("ror\n".utf8), stdout: false, timestamp: newer),
        ]
        var payload = Router.logHistoryPayload(
            chunks, tty: false, stdout: true, stderr: true, timestamps: true,
            since: older.addingTimeInterval(1), until: nil
        )
        let frames = DockerStdio.pullFrames(&payload).frames
        #expect(frames.map(\.stream) == [2])
        #expect(frames.map { String(decoding: $0.payload, as: UTF8.self) } == ["\(ISO8601.string(from: newer)) error\n"])
    }
}
