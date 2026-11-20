import ArgumentParser
import ContainerEngine
import Darwin
import Foundation

extension K3s {
    struct Kubectl: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run kubectl against the selected Macker K3s cluster.", helpNames: []
        )
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

        func run() throws {
            try Self.validateTarget(arguments)
            let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
            let bundled = executable?.deletingLastPathComponent().appendingPathComponent("k3s-tools/kubectl")
            let client = try Self.selectClient(path: ProcessInfo.processInfo.environment["PATH"], bundled: bundled)
            let status: Int32
            if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] ||
                arguments == ["version", "--client"] || arguments == ["version", "--client", "-o", "json"] {
                status = try Self.runClient(client, arguments: arguments)
            } else {
                let config = try K3s.fetchKubeconfig()
                status = try TemporaryDirectory.with("macker-kubectl") { dir in
                    let path = dir.appendingPathComponent("config").path
                    try K3s.writeKubeconfig(config, to: path)
                    return try Self.runClient(client, arguments: ["--kubeconfig", path] + arguments, kubeconfig: path)
                }
            }
            if status != 0 { throw ExitCode(status) }
        }

        static func validateTarget(_ arguments: [String]) throws {
            let targetFlags: Set<String> = ["--kubeconfig", "--context", "--cluster", "--server", "-s"]
            for arg in arguments.prefix(while: { $0 != "--" }) {
                let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
                if targetFlags.contains(name) || (name.hasPrefix("-s") && !name.hasPrefix("--")) {
                    throw ValidationError("\(name) cannot override the Macker cluster; use kubectl directly to select a different cluster")
                }
            }
        }

        static func selectClient(path: String?, bundled: URL?) throws -> URL {
            let fm = FileManager.default
            let system = path?.split(separator: ":").lazy.map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("kubectl")
            }.first { fm.isExecutableFile(atPath: $0.path) }
            if let system, let version = clientVersion(system), isCompatible(version) { return system }
            if let bundled, fm.isExecutableFile(atPath: bundled.path) { return bundled }
            throw CLIError.io("no compatible kubectl found; install the Macker CLI package or run 'make kubectl-tools' for a debug build")
        }

        private static func clientVersion(_ client: URL) -> String? {
            struct Version: Decodable {
                struct Client: Decodable { let gitVersion: String }
                let clientVersion: Client
            }
            let process = Process()
            process.executableURL = client
            process.arguments = ["version", "--client", "-o", "json"]
            let output = Pipe()
            process.standardOutput = output
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return (try? JSONDecoder().decode(Version.self, from: data))?.clientVersion.gitVersion
        }

        static func isCompatible(_ version: String) -> Bool {
            // Keep this range in sync with the pinned K3s image and staged kubectl.
            guard let range = version.range(of: #"^v1\.(33|34|35)\.[0-9]+(\+.*)?$"#, options: .regularExpression) else {
                return false
            }
            return range == version.startIndex..<version.endIndex
        }

        private static func runClient(_ client: URL, arguments: [String], kubeconfig: String? = nil) throws -> Int32 {
            // Spawn in the foreground process group, keeping the terminal and all three
            // standard streams. The parent waits so it can clean up the credential file.
            var attributes: posix_spawnattr_t?
            let initialized = posix_spawnattr_init(&attributes)
            guard initialized == 0 else { throw CLIError.io(String(cString: strerror(initialized))) }
            defer { posix_spawnattr_destroy(&attributes) }

            // The signal proxy keeps the parent alive; restore default behavior in kubectl.
            let signals = ProcessSignalProxy.forwarded
            var defaults = sigset_t()
            sigemptyset(&defaults)
            for (sig, _) in signals { sigaddset(&defaults, sig) }
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
            let argv = ([client.path] + arguments).map { strdup($0) } + [nil]
            var environment = ProcessInfo.processInfo.environment
            if let kubeconfig { environment["KUBECONFIG"] = kubeconfig }
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var pid: pid_t = 0
            // Install before spawning. Only the parent traps signals; limit the
            // forwarding window to the life of this child.
            let child = ChildSignalTarget()
            let proxy = ProcessSignalProxy(enabled: true) { name in
                if let sig = signals.first(where: { $0.1 == name })?.0 { child.forward(sig) }
            }
            defer { proxy.restore() }
            let result = posix_spawn(&pid, client.path, nil, &attributes, argv, envp)
            guard result == 0 else { throw CLIError.io("cannot start kubectl: \(String(cString: strerror(result)))") }
            child.started(pid)
            defer { child.finished() }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 {
                if errno == EINTR { continue }
                throw CLIError.io("cannot wait for kubectl: \(String(cString: strerror(errno)))")
            }
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : 128 + signal
        }
    }
}

private final class ChildSignalTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var pending: Int32?

    func started(_ pid: pid_t) {
        lock.withLock {
            self.pid = pid
            if let pending { kill(pid, pending) }
            pending = nil
        }
    }

    func finished() { lock.withLock { pid = nil } }

    func forward(_ signal: Int32) {
        lock.withLock {
            if let pid { kill(pid, signal) } else { pending = signal }
        }
    }
}
