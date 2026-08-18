import ArgumentParser
import Darwin
import Foundation
import MackerHelperSupport

struct HelperGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "Install the privileged helper that configures host routes into container subnets.",
        subcommands: [HelperInstall.self, HelperUninstall.self, HelperStatus.self],
        defaultSubcommand: HelperStatus.self
    )
}

struct HelperInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install macker-helper as a root LaunchDaemon (once; subsequent boots do not prompt)."
    )

    @Option(help: "UID allowed to configure routes. Defaults to SUDO_UID, or the current user.")
    var uid: UInt32?

    func run() throws {
        if geteuid() != 0 {
            throw ExitCode(try HelperInstaller.reexecAsRoot())
        }
        guard let binary = HelperInstaller.locateBinary() else {
            throw CLIError.io(HelperError.binaryNotFound.localizedDescription)
        }
        let target = try HelperInstaller.targetUID(explicit: uid)
        try HelperInstaller.install(binary: binary, uid: target)
        waitForHelper()
        print("  [ok  ] installed \(HelperPaths.installedBinaryPath)")
        print("         allowed uid \(target)")
        if HelperClient.isAvailable {
            print("  [ok  ] helper is running")
        } else {
            print("  [warn] helper plist loaded but socket is not up yet; check \(HelperPaths.logPath)")
        }
        print("Next: restart the daemon so it can attach utun routes. `-p` works without this.")
    }
}

struct HelperUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the host-route helper LaunchDaemon."
    )

    func run() throws {
        if geteuid() != 0 {
            throw ExitCode(try HelperInstaller.reexecAsRoot())
        }
        try HelperInstaller.uninstall()
        print("  [ok  ] removed \(HelperPaths.label)")
    }
}

struct HelperStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether the host-route helper is installed and reachable."
    )

    func run() throws {
        let fm = FileManager.default
        let binary = fm.isExecutableFile(atPath: HelperPaths.installedBinaryPath)
        let plist = fm.fileExists(atPath: HelperPaths.plistPath)
        print("Helper:  \(HelperPaths.label)")
        print("Binary:  \(HelperPaths.installedBinaryPath) \(binary ? "present" : "missing")")
        print("Plist:   \(HelperPaths.plistPath) \(plist ? "present" : "missing")")
        print("Socket:  \(HelperPaths.socketPath)")
        if let pong = try? HelperClient.ping() {
            print("Ping:    ok (protocol \(pong.version ?? 0))")
        } else if binary || plist {
            print("Ping:    not running — try `sudo macker helper install`")
            throw ExitCode(1)
        } else {
            print("Ping:    not installed — `sudo macker helper install` for curl <container IP>")
            throw ExitCode(1)
        }
    }
}

private func waitForHelper() {
    for _ in 0..<20 {
        if HelperClient.isAvailable { return }
        usleep(100_000)
    }
}
