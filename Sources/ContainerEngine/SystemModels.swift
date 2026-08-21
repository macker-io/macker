import Foundation

/// Host + daemon snapshot for `GET /info`.
public struct EngineSystemInfo: Sendable {
    public let id: String
    public let containers: Int
    public let containersRunning: Int
    public let containersPaused: Int
    public let containersStopped: Int
    public let images: Int
    public let dockerRootDir: String
    public let ncpu: Int
    public let memTotal: Int64
    public let hostname: String
    public let operatingSystem: String
    public let osVersion: String
    public let kernelVersion: String
    public let architecture: String
    public let eventListeners: Int
}

/// `GET /system/df` payload.
public struct EngineDiskUsage: Sendable {
    public let layersSize: Int64
    public let images: [EngineImageSummary]
    public let containers: [EngineContainerSummary]
    public let volumes: [EngineVolumeInfo]
}

/// One Docker-compatible daemon event (`GET /events`).
public struct EngineEvent: Sendable {
    public let type: String
    public let action: String
    public let actorID: String
    public let attributes: [String: String]
    public let time: Date

    public init(
        type: String,
        action: String,
        actorID: String,
        attributes: [String: String] = [:],
        time: Date = Date()
    ) {
        self.type = type
        self.action = action
        self.actorID = actorID
        self.attributes = attributes
        self.time = time
    }
}

/// In-process fan-out for live `/events` subscribers, plus a bounded replay buffer.
actor EventBus {
    /// Same size as Docker's in-memory event log.
    static let historyLimit = 256

    private var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var history: [EngineEvent] = []

    var listenerCount: Int { subscribers.count }

    func publish(_ event: EngineEvent) {
        if history.count == Self.historyLimit {
            history.removeFirst()
        }
        history.append(event)
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    func buffered(since: Date? = nil, until: Date? = nil) -> [EngineEvent] {
        history.filter { event in
            if let since, event.time < since { return false }
            if let until, event.time > until { return false }
            return true
        }
    }

    func subscribe() -> AsyncStream<EngineEvent> {
        liveStream()
    }

    /// Copies matching history, then registers the live subscriber in the same turn.
    func subscribe(since: Date?, until: Date?) -> (history: [EngineEvent], stream: AsyncStream<EngineEvent>) {
        (buffered(since: since, until: until), liveStream())
    }

    private func liveStream() -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id) }
            }
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
