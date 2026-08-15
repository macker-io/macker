import ArgumentParser
import ContainerEngine
import Darwin
import Foundation

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose the host, daemon socket, and Virtualization support."
    )

    func run() throws {
        print("Macker doctor")
        var results: [CheckResult] = []
        results.append(contentsOf: hostChecks())
        results.append(contentsOf: engineChecks())
        results.append(contentsOf: socketChecks())
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
            let (report, runtime) = try RunSync.call {
                let engine = try EngineManager()
                let report = try await engine.checkEnvironment()
                let runtime = await engine.runtimeStatus()
                return (report, runtime)
            }
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
            } else if runtime.vminitPresent {
                checks.append(CheckResult(status: .ok, title: "initfs", detail: runtime.vminitReference))
            } else {
                checks.append(CheckResult(status: .warn, title: "initfs / vminit", detail: "missing — first start pulls \(runtime.vminitReference)"))
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

    private func socketChecks() -> [CheckResult] {
        let path = DaemonAPI.socket
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
            results.append(CheckResult(status: .ok, title: "Docker socket symlink", detail: "\(compat) → \(dest)"))
        } else if FileManager.default.fileExists(atPath: compat) {
            results.append(CheckResult(status: .warn, title: "Docker socket symlink", detail: "\(compat) exists but is not Macker — run `macker setup --force`"))
        } else {
            results.append(CheckResult(status: .warn, title: "Docker socket symlink", detail: "\(compat) not linked — run `macker setup`"))
        }
        return results
    }
}
