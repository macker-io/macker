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

        let socketPath = parseSocketPath(from: CommandLine.arguments)
        let instanceLock: DaemonInstanceLock
        do {
            instanceLock = try DaemonInstanceLock.acquire()
        } catch {
            logger.error("\(error.localizedDescription)")
            exit(1)
        }

        let engine: EngineManager
        do {
            engine = try EngineManager()
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

        await signals.wait()
        logger.info("shutdown signal received, stopping")
        await engine.shutdown()
        await server.stop()
        _ = await serverTask.result
        instanceLock.release()
    }

    /// `--socket <path>` or `--socket=<path>`; else `MACKER_HOST` / `DOCKER_HOST`; else the store socket.
    static func parseSocketPath(from arguments: [String]) -> String {
        if let index = arguments.firstIndex(of: "--socket"), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        if let combined = arguments.first(where: { $0.hasPrefix("--socket=") }) {
            return String(combined.dropFirst("--socket=".count))
        }
        return DaemonPaths.socketPath()
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
