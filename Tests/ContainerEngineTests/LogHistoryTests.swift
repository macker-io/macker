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

    @Test func tailJoinsPipeFragmentsAndUsesCaptureTime() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_010)
        let chunks = [
            EngineIOChunk(data: Data("old\n".utf8), stdout: true, timestamp: older),
            EngineIOChunk(data: Data("er".utf8), stdout: false, timestamp: newer),
            EngineIOChunk(data: Data("ror\n".utf8), stdout: false, timestamp: newer),
        ]
        var payload = Router.logHistoryPayload(
            chunks, tty: false, stdout: true, stderr: true, timestamps: true,
            tail: "1", since: older.addingTimeInterval(1), until: nil
        )
        let frames = DockerStdio.pullFrames(&payload).frames
        #expect(frames.map(\.stream) == [2])
        #expect(frames.map { String(decoding: $0.payload, as: UTF8.self) } == ["\(ISO8601.string(from: newer)) error\n"])
    }
}
