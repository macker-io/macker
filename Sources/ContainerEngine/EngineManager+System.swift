import Darwin
import Foundation

extension EngineManager {
    /// Cheap snapshot for the desktop status item; does not query the image store.
    public func activityCounts() -> (runningContainers: Int, activeBuilds: Int) {
        (containers.values.count { !$0.isSystem && $0.state == "running" }, activeBuildCount)
    }

    /// Docker `GET /info` — host and daemon facts.
    public func systemInfo() async -> EngineSystemInfo {
        let containers = self.containers.values.filter { !$0.isSystem }
        let images = (try? await imageStore.list()) ?? []
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return EngineSystemInfo(
            id: daemonID,
            containers: containers.count,
            containersRunning: containers.filter { $0.state == "running" }.count,
            containersPaused: containers.filter { $0.state == "paused" }.count,
            containersStopped: containers.filter { $0.state == "exited" || $0.state == "created" }.count,
            images: images.count,
            dockerRootDir: imageStore.path.path,
            ncpu: ProcessInfo.processInfo.processorCount,
            memTotal: Self.hostMemoryBytes(),
            hostname: ProcessInfo.processInfo.hostName,
            operatingSystem: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            kernelVersion: Self.kernelRelease(),
            architecture: Self.isAppleSilicon ? "aarch64" : "x86_64",
            eventListeners: await eventBus.listenerCount
        )
    }

    /// Docker `GET /system/df`.
    public func diskUsage() async throws -> EngineDiskUsage {
        let images = try await listImages(all: true)
        var seen = Set<String>()
        var layersSize: Int64 = 0
        for image in try await imageStore.list() {
            guard let digests = try? await image.referencedDigests() else { continue }
            for digest in digests where seen.insert(digest).inserted {
                guard let content = try? await image.getContent(digest: digest) else { continue }
                layersSize += Int64((try? content.size()) ?? 0)
            }
        }
        return EngineDiskUsage(
            layersSize: layersSize,
            images: images,
            containers: self.containers.values.filter { !$0.isSystem }.map(\.summary),
            volumes: listVolumes()
        )
    }

    /// `GET /events`. `since` / `until` replay the in-memory buffer; live follows unless `until` is past.
    public func events(since: Date? = nil, until: Date? = nil) async -> AsyncStream<EngineEvent> {
        let live = until.map { $0 > Date() } ?? true
        let replay = since != nil || until != nil

        let history: [EngineEvent]
        let upstream: AsyncStream<EngineEvent>?
        if !live {
            history = await eventBus.buffered(since: since, until: until)
            upstream = nil
        } else if replay {
            (history, upstream) = await eventBus.subscribe(since: since, until: until)
        } else {
            history = []
            upstream = await eventBus.subscribe()
        }

        return AsyncStream { continuation in
            let worker = Task {
                for event in history {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                if let upstream {
                    for await event in upstream {
                        if Task.isCancelled { break }
                        if let until, event.time > until { break }
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            let sleeper: Task<Void, Never>?
            if live, let until {
                sleeper = Task {
                    let delay = until.timeIntervalSinceNow
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    guard !Task.isCancelled else { return }
                    worker.cancel()
                    continuation.finish()
                }
            } else {
                sleeper = nil
            }
            continuation.onTermination = { _ in
                worker.cancel()
                sleeper?.cancel()
            }
        }
    }

    private static func hostMemoryBytes() -> Int64 {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        return Int64(size)
    }

    private static func kernelRelease() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }
}
