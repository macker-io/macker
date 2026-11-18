import Foundation
import Testing
@testable import CliCore

/// `macker setup` / `macker doctor` against an in-memory Docker CLI and filesystem.
final class FakeSetupEnvironment: SetupEnvironment, @unchecked Sendable {
    var dockerInstalled = true
    var composeInstalled = true
    var contexts: [String: String] = [:]
    var current = "default"
    var files: [String: String] = [:]
    var symlinks: [String: String] = [:]
    var commands: [[String]] = []
    var apiResult = ProcessResult(status: 0, stdout: "1.44/1.44\n", stderr: "")
    let homeDirectory = "/home/test"

    func which(_ name: String) -> String? {
        name == "docker" && dockerInstalled ? "/usr/local/bin/docker" : nil
    }

    func run(_ executable: String, _ arguments: [String], timeoutSeconds: Int) -> ProcessResult {
        commands.append(arguments)
        func ok(_ out: String = "") -> ProcessResult { ProcessResult(status: 0, stdout: out, stderr: "") }
        func fail(_ err: String) -> ProcessResult { ProcessResult(status: 1, stdout: "", stderr: err) }
        switch Array(arguments.prefix(2)) {
        case ["--version"]:
            return ok("Docker version 29.8.2, build abc\n")
        case ["compose", "version"]:
            return composeInstalled ? ok("5.5.0\n") : fail("docker: unknown command: docker compose")
        case ["context", "inspect"]:
            guard let host = contexts[arguments[2]] else {
                return fail("context \"\(arguments[2])\": context not found: open meta.json: no such file or directory")
            }
            return ok(host + "\n")
        case ["context", "show"]:
            return ok(current + "\n")
        case ["context", "create"]:
            let host = arguments.first { $0.hasPrefix("host=") }.map { String($0.dropFirst(5)) } ?? ""
            contexts[arguments[2]] = host
            return ok()
        case ["context", "update"]:
            let host = arguments.first { $0.hasPrefix("host=") }.map { String($0.dropFirst(5)) } ?? ""
            contexts[arguments[2]] = host
            return ok()
        case ["context", "rm"]:
            if current == arguments[2], !arguments.contains("--force") {
                return fail("context is in use")
            }
            contexts[arguments[2]] = nil
            if current == arguments[2] { current = "default" }
            return ok()
        default:
            if arguments.first == "--host" {
                return apiResult
            }
            return fail("unexpected \(arguments)")
        }
    }

    func readFile(_ path: String) -> String? { files[path] }
    func fileExists(_ path: String) -> Bool { files[path] != nil || symlinks[path] != nil }
    func symlinkDestination(_ path: String) -> String? { symlinks[path] }
    func createSymlink(_ path: String, to destination: String) throws { symlinks[path] = destination }
    func removeItem(_ path: String) throws {
        files[path] = nil
        symlinks[path] = nil
    }

    var mutatingCommands: [[String]] {
        commands.filter { $0.count > 1 && $0[0] == "context" && ["create", "update", "rm", "use"].contains($0[1]) }
    }
}

struct DockerSetupTests {
    static let socket = "/Users/u/Library/Application Support/io.macker.daemon/macker.sock"

    func setup(_ env: FakeSetupEnvironment, _ options: SetupRunner.Options = .init()) -> (Bool, String) {
        var output: [String] = []
        let ok = SetupRunner(env: env, socketPath: Self.socket, options: options, print: { output.append($0) }).run()
        return (ok, output.joined(separator: "\n"))
    }

    @Test func absentContextIsCreatedWithoutSwitchingOrTouchingShellFiles() {
        let env = FakeSetupEnvironment()
        env.contexts["desktop-linux"] = "unix:///Users/u/.docker/run/docker.sock"
        let (ok, output) = setup(env)
        #expect(ok)
        #expect(env.contexts["macker"] == "unix://\(Self.socket)")
        #expect(env.contexts["desktop-linux"] == "unix:///Users/u/.docker/run/docker.sock")
        #expect(env.current == "default")
        #expect(env.files.isEmpty && env.symlinks.isEmpty)
        #expect(output.contains("docker --context macker"))
    }

    @Test func matchingContextIsIdempotent() {
        let env = FakeSetupEnvironment()
        env.contexts["macker"] = "unix://\(Self.socket)"
        let (ok, _) = setup(env)
        #expect(ok)
        #expect(env.mutatingCommands.isEmpty)
    }

    @Test func foreignContextIsRefusedUnlessForced() {
        let env = FakeSetupEnvironment()
        env.contexts["macker"] = "unix:///tmp/foreign.sock"
        let (refused, output) = setup(env)
        #expect(!refused)
        #expect(output.contains("--force"))
        #expect(env.contexts["macker"] == "unix:///tmp/foreign.sock")
        #expect(env.mutatingCommands.isEmpty)

        let (forced, _) = setup(env, .init(force: true))
        #expect(forced)
        #expect(env.contexts["macker"] == "unix://\(Self.socket)")
    }

    @Test func uninstallRemovesOnlyAMackerContext() {
        let env = FakeSetupEnvironment()
        env.contexts["macker"] = "unix:///tmp/foreign.sock"
        #expect(!setup(env, .init(uninstall: true)).0)
        #expect(env.contexts["macker"] != nil)

        env.contexts["macker"] = "unix://\(Self.socket)"
        env.current = "macker"
        let (refusedActive, output) = setup(env, .init(uninstall: true))
        #expect(!refusedActive)
        #expect(output.contains("docker context use default"))

        #expect(setup(env, .init(force: true, uninstall: true)).0)
        #expect(env.contexts["macker"] == nil)
        #expect(env.current == "default")
        #expect(setup(env, .init(uninstall: true)).0)  // nothing left: still success
    }

    @Test func dockerSocketLinkIsOptInAndNeverReplacesAnotherEngine() {
        let env = FakeSetupEnvironment()
        _ = setup(env)
        #expect(env.symlinks.isEmpty)

        env.symlinks["/var/run/docker.sock"] = "/Users/u/.orbstack/run/docker.sock"
        #expect(!setup(env, .init(dockerSocket: true)).0)
        #expect(env.symlinks["/var/run/docker.sock"] == "/Users/u/.orbstack/run/docker.sock")

        env.symlinks["/var/run/docker.sock"] = nil
        #expect(setup(env, .init(dockerSocket: true)).0)
        #expect(env.symlinks["/var/run/docker.sock"] == Self.socket)
        #expect(setup(env, .init(uninstall: true, dockerSocket: true)).0)
        #expect(env.symlinks["/var/run/docker.sock"] == nil)
    }

    @Test func dryRunChangesNothing() {
        let env = FakeSetupEnvironment()
        let (ok, output) = setup(env, .init(dryRun: true))
        #expect(ok)
        #expect(env.contexts.isEmpty)
        #expect(output.contains("would create"))
    }

    @Test func missingDockerCLIIsActionable() {
        let env = FakeSetupEnvironment()
        env.dockerInstalled = false
        let (ok, output) = setup(env)
        #expect(!ok)
        #expect(output.contains("docker CLI — not found"))
    }

    @Test func legacyAliasIsReportedButNotEdited() {
        let env = FakeSetupEnvironment()
        env.files["/home/test/.zshrc"] = "export X=1\nalias docker=\"macker\"\n"
        let (_, output) = setup(env)
        #expect(output.contains(".zshrc aliases docker to macker"))
        #expect(env.files["/home/test/.zshrc"] == "export X=1\nalias docker=\"macker\"\n")
    }

    @Test func doctorReportsEachToolchainFactSeparately() {
        let env = FakeSetupEnvironment()
        env.contexts["macker"] = "unix://\(Self.socket)"
        let checks = DockerDoctor(env: env).checks(daemonSocket: "/tmp/x.sock", contextSocket: Self.socket)
        #expect(checks.map(\.title) == ["docker CLI", "docker compose plugin", "docker context", "API version"])
        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(checks[3].detail == "client 1.44, server max 1.44")

        env.composeInstalled = false
        env.contexts = [:]
        env.apiResult = ProcessResult(status: 1, stdout: "", stderr: "Cannot connect")
        let degraded = DockerDoctor(env: env).checks(daemonSocket: "/tmp/x.sock", contextSocket: Self.socket)
        #expect(degraded.map(\.status) == [.ok, .warn, .warn, .fail])

        env.dockerInstalled = false
        let missing = DockerDoctor(env: env).checks(daemonSocket: "/tmp/x.sock", contextSocket: Self.socket)
        #expect(missing.first?.title == "docker CLI")
        #expect(missing.first?.status == .warn)
    }

    @Test func setupIgnoresDockerHostWhenChoosingTheSocket() {
        #expect(SetupRunner.daemonSocketPath(environment: ["DOCKER_HOST": "unix:///other.sock"]) != "/other.sock")
        #expect(SetupRunner.daemonSocketPath(environment: ["MACKER_HOST": "unix:///m.sock"]) == "/m.sock")
    }
}
