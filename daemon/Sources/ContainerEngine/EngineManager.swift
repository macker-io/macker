import Containerization
import Darwin
import Foundation
import Virtualization

/// Adapter around the Apple Containerization SDK.
public actor EngineManager {
    /// Maximum container ID length, matching `Containerization.LinuxContainer`.
    public static let maxContainerIDLength = LinuxContainer.maxIDLength

    public static var defaultStorePath: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.macker.daemon", isDirectory: true)
    }

    let imageStore: ImageStore
    let eventBus = EventBus()
    let daemonID: String
    let volumeRoot: URL
    var containers: [String: EngineContainer] = [:]
    var waiters: [String: [CheckedContinuation<Int, Never>]] = [:]
    var execs: [String: EngineExec] = [:]
    var attachSubscribers: [String: [UUID: AsyncStream<String>.Continuation]] = [:]
    var execSubscribers: [String: [UUID: AsyncStream<String>.Continuation]] = [:]
    var volumes: [String: EngineVolume] = [:]

    public init(storePath: URL? = nil) throws {
        let store = try ImageStore(path: storePath ?? Self.defaultStorePath)
        self.imageStore = store
        self.daemonID = Self.loadOrCreateDaemonID(in: store.path)
        let volumeRoot = store.path.appendingPathComponent("volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeRoot, withIntermediateDirectories: true)
        self.volumeRoot = volumeRoot
        self.volumes = Self.loadVolumes(from: volumeRoot)
    }

    /// Validates that this Mac can host MicroVMs via Virtualization.framework.
    public func checkEnvironment() async throws -> EnvironmentReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        guard version.majorVersion >= 15 else {
            throw EngineError.unsupportedHost(
                "macOS 15 or later is required (found \(version.majorVersion).\(version.minorVersion).\(version.patchVersion))"
            )
        }

        guard Self.isAppleSilicon else {
            throw EngineError.unsupportedHost("Apple Silicon (arm64) is required to run Linux MicroVMs")
        }

        guard VZVirtualMachine.isSupported else {
            throw EngineError.unsupportedHost("Virtualization.framework is not supported on this host")
        }

        return EnvironmentReport(
            isAppleSilicon: true,
            isVirtualizationSupported: true,
            macOSVersion: version
        )
    }

    func publish(_ event: EngineEvent) async {
        await eventBus.publish(event)
    }

    static func makeContainerID() -> String {
        let hex = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return String(hex.prefix(64))
    }

    static var isAppleSilicon: Bool {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine == "arm64"
    }

    private static func loadOrCreateDaemonID(in root: URL) -> String {
        let url = root.appendingPathComponent("daemon-id")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let id = UUID().uuidString
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }
}
