import ContainerEngine
import Darwin
import Dispatch
import DockerAPIAdapter
import Foundation
import Logging

@main
struct DaemonApp {
    static func main() async {
        var logger = Logger(label: "io.macker.daemon")
        logger.logLevel = .info

        let storeDirectory = parseStoreDirectory(from: CommandLine.arguments)
        let socketPath = parseSocketPath(from: CommandLine.arguments, store: storeDirectory)
        let instanceLock: DaemonInstanceLock
        do {
            instanceLock = try DaemonInstanceLock.acquire(storeDirectory: storeDirectory)
        } catch {
            logger.error("\(error.localizedDescription)")
            exit(1)
        }

        let engine: EngineManager
        do {
            engine = try EngineManager(storePath: storeDirectory)
        } catch {
            logger.error("failed to initialize image store: \(error.localizedDescription)")
            instanceLock.release()
            exit(1)
        }

        do {
            let report = try await engine.checkEnvironment()
            logger.info(
                "environment ok appleSilicon=\(report.isAppleSilicon) virtualization=\(report.isVirtualizationSupported) macOS=\(report.macOSVersion.majorVersion).\(report.macOSVersion.minorVersion).\(report.macOSVersion.patchVersion)"
            )
            let runtime = await engine.runtimeStatus()
            if let kernel = runtime.kernelPath {
                logger.info("runtime kernel=\(kernel)")
            } else {
                logger.warning("runtime kernel missing — package the app or run `macker fetch-runtime`")
            }
            if let initfs = runtime.initfsPath {
                logger.info("runtime initfs=\(initfs)")
            } else {
                logger.warning("runtime initfs missing — first container start will pull \(runtime.vminitReference)")
            }
        } catch {
            logger.error("environment check failed: \(error.localizedDescription)")
            instanceLock.release()
            exit(1)
        }

        do {
            try await engine.retainRestoredContainerImages()
        } catch {
            logger.error("failed to retain container images: \(error.localizedDescription)")
            instanceLock.release()
            exit(1)
        }

        let server = SocketServer(socketPath: socketPath, engine: engine, logger: logger)
        let signals = SignalWatcher()

        let serverTask = Task {
            do {
                try await server.start()
            } catch {
                logger.error("socket server failed: \(error.localizedDescription)")
                exit(1)
            }
        }

        await engine.startRestartPolicies()

        await signals.wait()
        logger.info("shutdown signal received, stopping")
        await engine.shutdown()
        await server.stop()
        _ = await serverTask.result
        instanceLock.release()
    }

    /// `--store <dir>` or `--store=<dir>`; else the default Application Support store.
    static func parseStoreDirectory(from arguments: [String]) -> URL {
        if let raw = option("store", from: arguments) {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return DaemonPaths.storeDirectory
    }

    /// `--socket <path>` or `--socket=<path>`; else `MACKER_HOST` / `DOCKER_HOST` when using the
    /// default store; else `macker.sock` under `--store`.
    static func parseSocketPath(from arguments: [String], store: URL) -> String {
        if let socket = option("socket", from: arguments) {
            return socket
        }
        if store.standardizedFileURL.path == DaemonPaths.storeDirectory.standardizedFileURL.path {
            return DaemonPaths.socketPath()
        }
        return DaemonPaths.socketFile(in: store)
    }

    static func option(_ name: String, from arguments: [String]) -> String? {
        let flag = "--\(name)"
        if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        let prefix = "\(flag)="
        if let combined = arguments.first(where: { $0.hasPrefix(prefix) }) {
            return String(combined.dropFirst(prefix.count))
        }
        return nil
    }
}

/// Keeps SIGINT/SIGTERM DispatchSources alive until the first signal arrives.
final class SignalWatcher: @unchecked Sendable {
    private let sigint: DispatchSourceSignal
    private let sigterm: DispatchSourceSignal
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    init() {
        var continuation: AsyncStream<Void>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation

        // Prevent the default terminate-process behavior so we can close the socket first.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        self.sigint = sigint
        self.sigterm = sigterm

        sigint.setEventHandler { continuation.yield(()) }
        sigterm.setEventHandler { continuation.yield(()) }
        sigint.resume()
        sigterm.resume()
    }

    func wait() async {
        for await _ in stream {
            break
        }
        sigint.cancel()
        sigterm.cancel()
    }
}
