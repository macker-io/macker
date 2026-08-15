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

/// In-process fan-out for live `/events` subscribers.
actor EventBus {
    private var subscribers: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    var listenerCount: Int { subscribers.count }

    func subscribe() -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.unsubscribe(id) }
            }
        }
    }

    func publish(_ event: EngineEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
