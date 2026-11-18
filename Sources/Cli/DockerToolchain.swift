import ContainerEngine
import Foundation

/// Everything `setup` and `doctor` need from the outside world, so the context state machine
/// can be tested without touching the real Docker config, shell files, or `/var/run`.
protocol SetupEnvironment {
    /// Absolute path of `name` on `PATH`, or `nil`.
    func which(_ name: String) -> String?
    /// Runs `executable` with `arguments`; the process inherits the caller's environment
    /// (so `DOCKER_CONFIG` / `HOME` select which Docker config is used).
    func run(_ executable: String, _ arguments: [String], timeoutSeconds: Int) -> ProcessResult
    func readFile(_ path: String) -> String?
    func fileExists(_ path: String) -> Bool
    func symlinkDestination(_ path: String) -> String?
    func createSymlink(_ path: String, to destination: String) throws
    func removeItem(_ path: String) throws
    var homeDirectory: String { get }
}

struct ProcessResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String

    var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    var message: String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? output : text
    }
}

/// Real process / filesystem access.
struct HostSetupEnvironment: SetupEnvironment {
    func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func run(_ executable: String, _ arguments: [String], timeoutSeconds: Int) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ProcessResult(status: 127, stdout: "", stderr: error.localizedDescription)
        }
        // Read both pipes concurrently so a chatty child cannot block on a full pipe.
        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + .seconds(2))
            return ProcessResult(status: 124, stdout: "", stderr: "timed out after \(timeoutSeconds)s")
        }
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    func readFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) || symlinkDestination(path) != nil
    }

    func symlinkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    func createSymlink(_ path: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }

    func removeItem(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    var homeDirectory: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
}

/// Read-only discovery of the official Docker toolchain; shared by `setup` and `doctor`.
struct DockerToolchainProbe {
    static let contextName = "macker"

    let env: SetupEnvironment

    struct Toolchain: Equatable {
        var dockerPath: String?
        var dockerVersion: String?
        var composeVersion: String?
    }

    enum ContextState: Equatable {
        case absent
        case matches
        /// The `macker` context exists but points at another endpoint.
        case foreign(String)
        /// `docker context inspect` failed for another reason.
        case unknown(String)
    }

    func toolchain() -> Toolchain {
        guard let docker = env.which("docker") else {
            return Toolchain(dockerPath: nil, dockerVersion: nil, composeVersion: nil)
        }
        let version = env.run(docker, ["--version"], timeoutSeconds: 10)
        let compose = env.run(docker, ["compose", "version", "--short"], timeoutSeconds: 10)
        return Toolchain(
            dockerPath: docker,
            dockerVersion: version.status == 0 ? Self.parseDockerVersion(version.output) : nil,
            composeVersion: compose.status == 0 && !compose.output.isEmpty ? compose.output : nil
        )
    }

    /// `Docker version 29.8.2, build abc` → `29.8.2`.
    static func parseDockerVersion(_ text: String) -> String {
        let prefix = "Docker version "
        guard text.hasPrefix(prefix) else { return text }
        let rest = text.dropFirst(prefix.count)
        return String(rest.prefix { $0 != "," && $0 != " " })
    }

    func contextState(docker: String, endpoint: String) -> ContextState {
        let result = env.run(
            docker,
            ["context", "inspect", Self.contextName, "--format", "{{.Endpoints.docker.Host}}"],
            timeoutSeconds: 10
        )
        if result.status != 0 {
            let message = result.message
            if message.contains("not found") || message.contains("does not exist") {
                return .absent
            }
            return .unknown(message)
        }
        let host = result.output
        return host == endpoint ? .matches : .foreign(host)
    }

    /// Name of the active context (`docker context show`).
    func currentContext(docker: String) -> String? {
        let result = env.run(docker, ["context", "show"], timeoutSeconds: 10)
        return result.status == 0 ? result.output : nil
    }

    /// Client and server API versions after the official client's negotiation, as `client/server`.
    func negotiatedAPI(docker: String, endpoint: String) -> ProcessResult {
        env.run(
            docker,
            ["--host", endpoint, "version", "--format", "{{.Client.APIVersion}}/{{.Server.APIVersion}}"],
            timeoutSeconds: 15
        )
    }

    /// Shell startup files that still route `docker` through the legacy `alias docker=macker`.
    func legacyAliases() -> [String] {
        let home = env.homeDirectory
        let files = [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile", ".config/fish/config.fish"]
        return files.map { "\(home)/\($0)" }.filter { path in
            guard let text = env.readFile(path) else { return false }
            return text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("#") && trimmed.contains("alias docker") && trimmed.contains("macker")
            }
        }
    }
}

/// Manages the `macker` Docker context without changing the active context.
enum DockerContextPlan: Equatable {
    case create
    case keep
    case update(from: String)
    case refuse(String)
    case remove
    case nothingToRemove
    case refuseRemoval(String)

    static func plan(
        state: DockerToolchainProbe.ContextState,
        endpoint: String,
        force: Bool,
        uninstall: Bool,
        active: Bool
    ) -> DockerContextPlan {
        let name = DockerToolchainProbe.contextName
        if uninstall {
            switch state {
            case .absent:
                return .nothingToRemove
            case .foreign(let host):
                return .refuseRemoval(
                    "context \"\(name)\" points at \(host), not Macker (\(endpoint)); leaving it in place. "
                        + "Remove it yourself with `docker context rm \(name)` if it is stale."
                )
            case .unknown(let message):
                return .refuseRemoval("cannot inspect context \"\(name)\": \(message)")
            case .matches:
                if active, !force {
                    return .refuseRemoval(
                        "context \"\(name)\" is the active Docker context; run `docker context use default` first, "
                            + "or pass --force to remove it anyway"
                    )
                }
                return .remove
            }
        }
        switch state {
        case .absent:
            return .create
        case .matches:
            return .keep
        case .foreign(let host):
            if force {
                return .update(from: host)
            }
            return .refuse(
                "context \"\(name)\" already exists and points at \(host), not \(endpoint). "
                    + "Nothing was changed. Re-run with --force to point it at Macker."
            )
        case .unknown(let message):
            return .refuse("cannot inspect context \"\(name)\": \(message)")
        }
    }
}
