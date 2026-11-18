import Containerization
import Darwin
import Foundation
import Virtualization

/// Adapter around the Apple Containerization SDK.
public actor EngineManager {
    /// Maximum container ID length, matching `Containerization.LinuxContainer`.
    public static let maxContainerIDLength = LinuxContainer.maxIDLength

    public static var defaultStorePath: URL { DaemonPaths.storeDirectory }

    let imageStore: ImageStore
    let authStore: RegistryAuthStore
    let eventBus = EventBus()
    let daemonID: String
    let containerRoot: URL
    let volumeRoot: URL
    let networkRoot: URL
    let portPublisher = PortPublisher()
    var containers: [String: EngineContainer] = [:]
    var waiters: [String: [UUID: EngineWaiter]] = [:]
    /// stdout/stderr sinks of the running VM, drained before an exit is published.
    var outputSinks: [String: [ProcessLogSink]] = [:]
    var execSinks: [String: [ProcessLogSink]] = [:]
    /// Output not yet terminated by a newline, per container and stream (`true` = stdout).
    var pendingLogLines: [String: [Bool: EngineIOChunk]] = [:]
    var execs: [String: EngineExec] = [:]
    var execProcesses: [String: LinuxProcess] = [:]
    var execStdin: [String: ProcessStdin] = [:]
    var execWaitTasks: [String: Task<Void, Never>] = [:]
    var containerStdin: [String: ProcessStdin] = [:]
    var attachSubscribers: [String: [UUID: EngineIOSubscriber]] = [:]
    var execSubscribers: [String: [UUID: AsyncStream<EngineIOChunk>.Continuation]] = [:]
    var ttySessions: [String: TTYSession] = [:]
    var statsSamples: [String: (busy: UInt64, total: UInt64)] = [:]
    var lastStats: [String: EngineContainerStats] = [:]
    var volumes: [String: EngineVolume] = [:]
    var networks: [String: EngineNetwork] = [:]
    let networkDataplane = NetworkDataplane()
    let networkGateway = NetworkGateway()
    var gatewayReady = false
    var containerManager: ContainerManager?
    var vms: [String: LinuxContainer] = [:]
    var activeBuildCount = 0
    var manuallySignaledForExit: Set<String> = []
    var waitTasks: [String: Task<Void, Never>] = [:]
    /// Boots in flight, so a second `start` (API client vs. restart policy) joins the first
    /// instead of booting a second MicroVM for the same container.
    var startTasks: [String: (token: UUID, task: Task<Bool, Error>)] = [:]
    /// In-flight boot of the hidden BuildKit builder.
    var buildKitBoot: Task<String, Error>?
    var healthTasks: [String: Task<Void, Never>] = [:]
    var guestNics: [String: [GuestNic]] = [:]
    let restartAfterDaemon: [String]

    public init(storePath: URL? = nil) throws {
        let store = try ImageStore(path: storePath ?? Self.defaultStorePath)
        self.imageStore = store
        self.authStore = RegistryAuthStore(directory: store.path)
        self.daemonID = Self.loadOrCreateDaemonID(in: store.path)
        let containerRoot = store.path.appendingPathComponent("containers", isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        self.containerRoot = containerRoot
        var loadedContainers = Self.loadContainers(from: containerRoot)
        self.restartAfterDaemon = Self.restoreContainers(&loadedContainers, root: containerRoot)
        self.containers = loadedContainers
        let volumeRoot = store.path.appendingPathComponent("volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeRoot, withIntermediateDirectories: true)
        self.volumeRoot = volumeRoot
        self.volumes = Self.loadVolumes(from: volumeRoot)
        let networkRoot = store.path.appendingPathComponent("networks", isDirectory: true)
        try FileManager.default.createDirectory(at: networkRoot, withIntermediateDirectories: true)
        self.networkRoot = networkRoot
        var loaded = Self.loadNetworks(from: networkRoot)
        try Self.ensureBuiltinNetworks(into: &loaded, root: networkRoot)
        self.networks = loaded
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
        // Daemon-owned helper containers stay invisible to `docker events`.
        let subject = event.type == "container" ? event.actorID : (event.attributes["container"] ?? "")
        if !subject.isEmpty, containers[subject]?.isSystem == true {
            return
        }
        await eventBus.publish(event)
    }

    static func killSuppressesRestart(_ signal: Signal, stopSignal: String) -> Bool {
        signal == .kill || signal == parsedKillSignal(stopSignal)
    }

    static func parsedKillSignal(_ raw: String) -> Signal {
        (try? Signal(raw)) ?? .term
    }

    /// `SIGTERM`, `TERM`, or `15`; anything else is an invalid argument.
    static func killSignal(_ raw: String) throws -> Signal {
        do {
            return try Signal(raw)
        } catch {
            throw EngineError.invalidArgument("Invalid signal: \(raw)")
        }
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
