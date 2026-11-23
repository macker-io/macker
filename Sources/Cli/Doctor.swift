import ArgumentParser
import ContainerEngine
import Darwin
import Foundation
import HelperSupport

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose the host, daemon socket, Docker CLI/context, and Virtualization support."
    )

    func run() throws {
        print("Macker doctor")
        var results: [CheckResult] = []
        results.append(contentsOf: hostChecks())
        results.append(contentsOf: engineChecks())
        results.append(contentsOf: try socketChecks())
        results.append(contentsOf: DockerDoctor(env: HostSetupEnvironment()).checks(
            daemonSocket: try DaemonAPI.socket(),
            contextSocket: SetupRunner.daemonSocketPath()
        ))
        results.append(contentsOf: helperChecks())
        Report.print(results)
        print("")
        let fails = results.filter { $0.status == .fail }.count
        let warns = results.filter { $0.status == .warn }.count
        print("\(fails) failure(s), \(warns) warning(s)")
        let code = Report.exitCode(for: results)
        if code != 0 {
            throw ExitCode(code)
        }
    }

    private func hostChecks() -> [CheckResult] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionText =
            "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let macos: CheckResult = version.majorVersion >= 15
            ? CheckResult(status: .ok, title: "macOS 15+", detail: versionText)
            : CheckResult(status: .fail, title: "macOS 15+", detail: "found \(versionText)")
        let networking: CheckResult = version.majorVersion >= 26
            ? CheckResult(status: .ok, title: "Container networking", detail: "macOS 26+ (\(versionText))")
            : CheckResult(
                status: .warn,
                title: "Container networking",
                detail: "bridge/host require macOS 26+ (found \(versionText))"
            )

        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        let silicon: CheckResult = machine == "arm64"
            ? CheckResult(status: .ok, title: "Apple Silicon", detail: machine)
            : CheckResult(status: .fail, title: "Apple Silicon", detail: "found \(machine)")

        return [macos, networking, silicon]
    }

    private func engineChecks() -> [CheckResult] {
        do {
            let report = try EngineManager.checkHostEnvironment()
            let runtime = RuntimeAssets.inspectFiles()
            var checks = [
                CheckResult(
                    status: report.isVirtualizationSupported ? .ok : .fail,
                    title: "Virtualization.framework",
                    detail: report.isVirtualizationSupported ? "supported" : "not supported"
                )
            ]
            if let kernel = runtime.kernelPath {
                checks.append(CheckResult(status: .ok, title: "Guest kernel", detail: kernel))
            } else {
                checks.append(CheckResult(status: .warn, title: "Guest kernel", detail: "missing — first start downloads it, or run `macker fetch-runtime`"))
            }
            if let initfs = runtime.initfsPath {
                checks.append(CheckResult(status: .ok, title: "initfs", detail: initfs))
            } else {
                checks.append(CheckResult(status: .warn, title: "initfs", detail: "not unpacked — first start prepares \(runtime.vminitReference)"))
            }
            return checks
        } catch {
            return [
                CheckResult(
                    status: .fail,
                    title: "ContainerEngine environment",
                    detail: error.localizedDescription
                )
            ]
        }
    }

    private func socketChecks() throws -> [CheckResult] {
        let path = try DaemonAPI.socket()
        var results: [CheckResult] = []
        if FileManager.default.fileExists(atPath: path) {
            results.append(CheckResult(status: .ok, title: "Socket file", detail: path))
        } else {
            results.append(CheckResult(status: .fail, title: "Socket file", detail: "\(path) is missing — is the daemon running?"))
        }

        do {
            let response = try DaemonAPI.get("/_ping")
            let body = String(data: response.body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if response.statusCode == 200 {
                results.append(CheckResult(status: .ok, title: "Daemon ping", detail: body.isEmpty ? "HTTP 200" : body))
            } else {
                results.append(CheckResult(status: .fail, title: "Daemon ping", detail: "HTTP \(response.statusCode)"))
            }
        } catch {
            results.append(CheckResult(status: .fail, title: "Daemon ping", detail: error.localizedDescription))
        }

        let compat = DaemonPaths.dockerCompatSocketPath
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: compat),
            dest == path
        {
            results.append(CheckResult(status: .ok, title: "Docker socket symlink", detail: "\(compat) → \(dest) (optional)"))
        }
        return results
    }

    private func helperChecks() -> [CheckResult] {
        if let pong = try? HelperClient.ping() {
            let version = pong.version.map(String.init) ?? "?"
            return [
                CheckResult(
                    status: .ok,
                    title: "Host-route helper",
                    detail: "\(HelperPaths.label) protocol \(version)"
                )
            ]
        }
        let installed = FileManager.default.fileExists(atPath: HelperPaths.plistPath)
            || FileManager.default.isExecutableFile(atPath: HelperPaths.installedBinaryPath)
        if installed {
            return [
                CheckResult(
                    status: .warn,
                    title: "Host-route helper",
                    detail: "installed but not running — sudo macker helper install"
                )
            ]
        }
        return [
            CheckResult(
                status: .warn,
                title: "Host-route helper",
                detail: "not installed — sudo macker helper install (optional; needed to curl container IPs)"
            )
        ]
    }
}

/// Official Docker client checks, one line each: CLI, Compose plugin, context, API negotiation.
struct DockerDoctor {
    let env: SetupEnvironment

    func checks(daemonSocket: String, contextSocket: String) -> [CheckResult] {
        let probe = DockerToolchainProbe(env: env)
        let toolchain = probe.toolchain()
        guard let docker = toolchain.dockerPath else {
            return [
                CheckResult(status: .warn, title: "docker CLI", detail: "not found on PATH — install it (e.g. `brew install docker`) to use the official client; `macker` works without it"),
                CheckResult(status: .warn, title: "docker compose plugin", detail: "optional external plugin skipped; packaged macker compose is independent"),
            ]
        }
        var results: [CheckResult] = [
            CheckResult(status: .ok, title: "docker CLI", detail: "\(toolchain.dockerVersion ?? "unknown version") at \(docker)")
        ]
        if let compose = toolchain.composeVersion {
            results.append(CheckResult(status: .ok, title: "docker compose plugin", detail: compose))
        } else {
            results.append(CheckResult(status: .warn, title: "docker compose plugin", detail: "optional for docker compose; use macker compose with the packaged CLI instead"))
        }
        let endpoint = "unix://\(contextSocket)"
        switch probe.contextState(docker: docker, endpoint: endpoint) {
        case .matches:
            let active = probe.currentContext(docker: docker) == DockerToolchainProbe.contextName
            results.append(CheckResult(status: .ok, title: "docker context", detail: "macker → \(endpoint)\(active ? " (active)" : "")"))
        case .absent:
            results.append(CheckResult(status: .warn, title: "docker context", detail: "\"macker\" not registered — run `macker setup`"))
        case .foreign(let host):
            results.append(CheckResult(status: .warn, title: "docker context", detail: "\"macker\" points at \(host), not \(endpoint) — run `macker setup --force`"))
        case .unknown(let message):
            results.append(CheckResult(status: .warn, title: "docker context", detail: message))
        }
        let api = probe.negotiatedAPI(docker: docker, endpoint: "unix://\(daemonSocket)")
        if api.status == 0 {
            let parts = api.output.split(separator: "/").map(String.init)
            let detail = parts.count == 2 ? "client \(parts[0]), server max \(parts[1])" : api.output
            results.append(CheckResult(status: .ok, title: "API version", detail: detail))
        } else {
            results.append(CheckResult(status: .fail, title: "API version", detail: "docker could not negotiate with unix://\(daemonSocket): \(api.message)"))
        }
        return results
    }
}
