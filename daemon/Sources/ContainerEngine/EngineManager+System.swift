import Darwin
import Foundation

extension EngineManager {
    /// Docker `GET /info` — host and daemon facts.
    public func systemInfo() async -> EngineSystemInfo {
        let containers = Array(self.containers.values)
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
            containers: Array(self.containers.values.map(\.summary)),
            volumes: listVolumes()
        )
    }

    /// Live event stream for `GET /events`. Historical log is not persisted.
    public func events(until: Date? = nil) async -> AsyncStream<EngineEvent> {
        if let until, until <= Date() {
            return AsyncStream { $0.finish() }
        }

        let upstream = await eventBus.subscribe()
        return AsyncStream { continuation in
            let worker = Task {
                for await event in upstream {
                    if Task.isCancelled { break }
                    if let until, Date() >= until { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            if let until {
                Task {
                    let delay = until.timeIntervalSinceNow
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    worker.cancel()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
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
