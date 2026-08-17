import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct EventsTests {
    @Test func bufferDropsOldestPastLimit() async {
        let bus = EventBus()
        for i in 0..<(EventBus.historyLimit + 3) {
            await bus.publish(EngineEvent(type: "container", action: "create", actorID: "\(i)"))
        }
        let buffered = await bus.buffered()
        #expect(buffered.count == EventBus.historyLimit)
        #expect(buffered.first?.actorID == "3")
        #expect(buffered.last?.actorID == "\(EventBus.historyLimit + 2)")
    }

    @Test func liveSubscribeSkipsHistory() async {
        let bus = EventBus()
        await bus.publish(EngineEvent(type: "container", action: "create", actorID: "old"))
        let stream = await bus.subscribe()
        await bus.publish(EngineEvent(type: "container", action: "start", actorID: "new"))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.actorID == "new")
    }

    @Test func replaySubscribeSnapshotsThenLive() async {
        let bus = EventBus()
        await bus.publish(EngineEvent(type: "container", action: "create", actorID: "old"))
        let (history, stream) = await bus.subscribe(since: Date.distantPast, until: nil)
        #expect(history.map(\.actorID) == ["old"])
        await bus.publish(EngineEvent(type: "container", action: "start", actorID: "new"))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.actorID == "new")
    }

    @Test func bufferedHonorsSinceAndUntil() async {
        let bus = EventBus()
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = Date(timeIntervalSince1970: 200)
        let t2 = Date(timeIntervalSince1970: 300)
        await bus.publish(EngineEvent(type: "container", action: "create", actorID: "a", time: t0))
        await bus.publish(EngineEvent(type: "container", action: "start", actorID: "b", time: t1))
        await bus.publish(EngineEvent(type: "container", action: "die", actorID: "c", time: t2))
        let slice = await bus.buffered(since: t1, until: t1)
        #expect(slice.map(\.actorID) == ["b"])
    }

    @Test func sinceReplaysThenFinishesWhenUntilIsPast() async throws {
        try await withEngine { engine in
            await engine.publish(
                EngineEvent(type: "container", action: "create", actorID: "abc", time: Date().addingTimeInterval(-30))
            )
            let events = await collect(
                await engine.events(since: Date().addingTimeInterval(-60), until: Date().addingTimeInterval(-1))
            )
            #expect(events.map(\.actorID) == ["abc"])
        }
    }

    @Test func untilInThePastReplaysBuffer() async throws {
        try await withEngine { engine in
            await engine.publish(
                EngineEvent(type: "container", action: "create", actorID: "old", time: Date().addingTimeInterval(-10))
            )
            let events = await collect(await engine.events(until: Date().addingTimeInterval(-1)))
            #expect(events.map(\.actorID) == ["old"])
        }
    }

    @Test func withoutSinceOrUntilDoesNotReplay() async throws {
        try await withEngine { engine in
            await engine.publish(
                EngineEvent(type: "container", action: "create", actorID: "old", time: Date().addingTimeInterval(-5))
            )
            let stream = await engine.events()
            var iterator = stream.makeAsyncIterator()
            await engine.publish(EngineEvent(type: "container", action: "start", actorID: "new"))
            #expect(await iterator.next()?.actorID == "new")
        }
    }

    @Test func parseUnixAndISO8601() {
        #expect(Router.parseTimestamp("0") == Date(timeIntervalSince1970: 0))
        #expect(Router.parseTimestamp("1136073600") == Date(timeIntervalSince1970: 1_136_073_600))
        #expect(Router.parseTimestamp("2020-01-01T00:00:00Z") == Date(timeIntervalSince1970: 1_577_836_800))
        #expect(Router.parseTimestamp(nil) == nil)
        #expect(Router.parseTimestamp("") == nil)
        #expect(Router.parseTimestamp("not-a-time") == nil)
    }

    @Test func parseGoDurationLooksBackFromNow() {
        let parsed = Router.parseTimestamp("10m")
        let expected = Date().addingTimeInterval(-600)
        #expect(parsed != nil)
        #expect(abs(parsed!.timeIntervalSince(expected)) < 2)
        #expect(Router.parseGoDuration("1h30m") == 5400)
        #expect(Router.parseGoDuration("2s") == 2)
        #expect(Router.parseGoDuration("-10s") == -10)
    }

    @Test func matchesTypeEventAndActors() {
        let container = EngineEvent(
            type: "container",
            action: "start",
            actorID: "abc123",
            attributes: ["name": "web", "image": "nginx"]
        )
        let volume = EngineEvent(type: "volume", action: "create", actorID: "data")
        #expect(Router.matches(container, filters: ["type": ["container"]]))
        #expect(!Router.matches(container, filters: ["type": ["image"]]))
        #expect(Router.matches(container, filters: ["event": ["start", "die"]]))
        #expect(!Router.matches(container, filters: ["event": ["create"]]))
        #expect(Router.matches(container, filters: ["container": ["web"]]))
        #expect(Router.matches(container, filters: ["container": ["abc"]]))
        #expect(!Router.matches(volume, filters: ["container": ["web"]]))
        #expect(Router.matches(container, filters: ["image": ["nginx"]]))
        #expect(Router.matches(volume, filters: ["volume": ["data"]]))
    }
}

private func collect(_ stream: AsyncStream<EngineEvent>) async -> [EngineEvent] {
    var events: [EngineEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func withEngine(_ body: (EngineManager) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macker-events-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(try EngineManager(storePath: dir))
}
