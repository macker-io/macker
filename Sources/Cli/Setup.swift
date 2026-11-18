import ArgumentParser
import ContainerEngine
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register a `macker` Docker context for the official docker CLI and Compose.",
        discussion: """
        Creates (or verifies) the Docker context `macker` pointing at the Macker daemon socket,
        using `docker context create`. The active context is never switched: use
        `docker --context macker …` or `docker context use macker`. No shell files are edited.
        """
    )

    @Flag(name: .long, help: "Point an existing `macker` context that targets another endpoint at Macker (or remove the active context with --uninstall).")
    var force = false

    @Flag(name: .long, help: "Remove the `macker` context (only if it points at Macker).")
    var uninstall = false

    @Flag(name: .long, help: "Also symlink /var/run/docker.sock to the Macker socket (opt-in; usually needs sudo).")
    var dockerSocket = false

    @Flag(name: .long, help: "Print the planned changes without making them.")
    var dryRun = false

    func run() throws {
        let runner = SetupRunner(
            env: HostSetupEnvironment(),
            socketPath: SetupRunner.daemonSocketPath(),
            options: .init(force: force, uninstall: uninstall, dockerSocket: dockerSocket, dryRun: dryRun),
            print: { Swift.print($0) }
        )
        if !runner.run() {
            throw ExitCode(1)
        }
    }
}

/// `macker setup` logic over an injected ``SetupEnvironment``.
struct SetupRunner {
    struct Options: Equatable {
        var force = false
        var uninstall = false
        var dockerSocket = false
        var dryRun = false
    }

    let env: SetupEnvironment
    let socketPath: String
    let options: Options
    let print: (String) -> Void

    var endpoint: String { "unix://\(socketPath)" }

    /// `MACKER_HOST`, else the default store's socket. `DOCKER_HOST` is deliberately ignored:
    /// it usually names the user's *other* engine, which the context must not point at.
    static func daemonSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let value = environment["MACKER_HOST"], let path = DaemonPaths.unixSocketPath(from: value) {
            return path
        }
        return DaemonPaths.defaultSocketPath
    }

    /// Returns `false` when something needs the user's attention (non-zero exit).
    func run() -> Bool {
        let probe = DockerToolchainProbe(env: env)
        print("Macker setup")
        print("  daemon socket: \(socketPath)")
        guard let docker = env.which("docker") else {
            print("  [fail] docker CLI — not found on PATH. Install the Docker CLI (e.g. `brew install docker docker-compose`), then re-run `macker setup`.")
            return false
        }
        var ok = applyContext(probe: probe, docker: docker)
        if options.dockerSocket {
            ok = applySocketLink() && ok
        }
        reportAliases(probe)
        if ok, !options.uninstall {
            print("")
            print("Use it with:  docker --context macker ps      (or once: docker context use macker)")
            print("Compose:      docker --context macker compose up -d")
            print("Check:        macker doctor")
        }
        return ok
    }

    private func applyContext(probe: DockerToolchainProbe, docker: String) -> Bool {
        let name = DockerToolchainProbe.contextName
        let state = probe.contextState(docker: docker, endpoint: endpoint)
        let active = probe.currentContext(docker: docker) == name
        let plan = DockerContextPlan.plan(
            state: state,
            endpoint: endpoint,
            force: options.force,
            uninstall: options.uninstall,
            active: active
        )
        switch plan {
        case .keep:
            print("  [ok  ] docker context \"\(name)\" → \(endpoint)")
            return true
        case .refuse(let message), .refuseRemoval(let message):
            print("  [fail] \(message)")
            return false
        case .nothingToRemove:
            print("  [ok  ] docker context \"\(name)\" is not registered")
            return true
        case .create:
            return change(
                "create docker context \"\(name)\" → \(endpoint)",
                docker,
                ["context", "create", name, "--description", "Macker MicroVM containers", "--docker", "host=\(endpoint)"]
            )
        case .update(let from):
            return change(
                "update docker context \"\(name)\": \(from) → \(endpoint)",
                docker,
                ["context", "update", name, "--docker", "host=\(endpoint)"]
            )
        case .remove:
            var arguments = ["context", "rm", name]
            if active {
                arguments.append("--force")
            }
            return change("remove docker context \"\(name)\"", docker, arguments)
        }
    }

    private func change(_ summary: String, _ docker: String, _ arguments: [String]) -> Bool {
        if options.dryRun {
            print("  [plan] would \(summary)")
            return true
        }
        let result = env.run(docker, arguments, timeoutSeconds: 20)
        if result.status != 0 {
            print("  [fail] could not \(summary): \(result.message)")
            return false
        }
        print("  [ok  ] \(summary)")
        return true
    }

    /// Opt-in `/var/run/docker.sock` → Macker socket. Never replaces another engine's socket
    /// without `--force`; `--uninstall` removes it only when it points at Macker.
    private func applySocketLink() -> Bool {
        let link = DaemonPaths.dockerCompatSocketPath
        let current = env.symlinkDestination(link)
        if options.uninstall {
            guard current == socketPath else {
                print("  [ok  ] \(link) does not point at Macker; left alone")
                return true
            }
            if options.dryRun {
                print("  [plan] would remove \(link)")
                return true
            }
            do {
                try env.removeItem(link)
                print("  [ok  ] removed \(link)")
                return true
            } catch {
                print("  [fail] could not remove \(link): \(error.localizedDescription) — run: sudo rm \(link)")
                return false
            }
        }
        if current == socketPath {
            print("  [ok  ] \(link) → \(socketPath)")
            return true
        }
        let exists = env.fileExists(link)
        if exists, !options.force {
            print("  [fail] \(link) already exists (\(current ?? "not a symlink")); re-run with --force to replace it")
            return false
        }
        if options.dryRun {
            print("  [plan] would \(exists ? "replace" : "create") \(link) → \(socketPath)")
            return true
        }
        do {
            if exists {
                try env.removeItem(link)
            }
            try env.createSymlink(link, to: socketPath)
            print("  [ok  ] \(link) → \(socketPath)")
            return true
        } catch {
            print("  [fail] could not link \(link): \(error.localizedDescription) — run: sudo ln -sfn \(socketPath) \(link)")
            return false
        }
    }

    /// Old releases appended `alias docker="macker"`; point it out, never edit shell files.
    private func reportAliases(_ probe: DockerToolchainProbe) {
        for file in probe.legacyAliases() {
            print("  [warn] \(file) aliases docker to macker; delete that line so `docker` is the official CLI again")
        }
    }
}
