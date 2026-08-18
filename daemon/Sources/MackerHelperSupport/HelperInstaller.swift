import Darwin
import Foundation

/// Installs `io.macker.helper` as a root LaunchDaemon so `mackerd` can attach utun without staying root.
public enum HelperInstaller: Sendable {
    public static func locateBinary(argv0: String = CommandLine.arguments[0]) -> URL? {
        let fm = FileManager.default
        let cli = URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
        let directory = cli.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("macker-helper"),
            directory.appendingPathComponent("io.macker.helper"),
            HelperPaths.installedBinaryURL,
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// User who runs `mackerd`. `sudo` sets `SUDO_UID`; a root shell must pass `--uid`.
    public static func targetUID(explicit: UInt32?) throws -> uid_t {
        if let explicit {
            return uid_t(explicit)
        }
        if let env = ProcessInfo.processInfo.environment["SUDO_UID"], let value = uid_t(env) {
            return value
        }
        let uid = getuid()
        if uid != 0 {
            return uid
        }
        throw HelperError.invalidRequest("pass --uid of the user who runs mackerd")
    }

    public static func launchDaemonPlist(program: String = HelperPaths.installedBinaryPath) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(HelperPaths.label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(program)</string>
        \t\t<string>serve</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>StandardOutPath</key>
        \t<string>\(HelperPaths.logPath)</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(HelperPaths.logPath)</string>
        </dict>
        </plist>

        """
    }

    public static func install(binary: URL, uid: uid_t, fileManager: FileManager = .default) throws {
        guard geteuid() == 0 else { throw HelperError.notRoot }
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: "/Library/PrivilegedHelperTools"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: HelperPaths.supportDirectory),
            withIntermediateDirectories: true
        )
        let source = binary.resolvingSymlinksInPath()
        let destination = HelperPaths.installedBinaryURL.resolvingSymlinksInPath()
        if source != destination {
            if fileManager.fileExists(atPath: HelperPaths.installedBinaryPath) {
                try fileManager.removeItem(atPath: HelperPaths.installedBinaryPath)
            }
            try fileManager.copyItem(at: source, to: HelperPaths.installedBinaryURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: HelperPaths.installedBinaryPath
        )
        try HelperPaths.writeAllowedUIDs([uid])
        try launchDaemonPlist().write(toFile: HelperPaths.plistPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: HelperPaths.plistPath
        )
        try reloadLaunchDaemon()
    }

    public static func uninstall(fileManager: FileManager = .default) throws {
        guard geteuid() == 0 else { throw HelperError.notRoot }
        _ = try? runLaunchctl(["bootout", "system/\(HelperPaths.label)"])
        unlink(HelperPaths.socketPath)
        for path in [
            HelperPaths.plistPath,
            HelperPaths.installedBinaryPath,
            HelperPaths.allowedUIDsPath,
            HelperPaths.logPath,
        ] where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        if fileManager.fileExists(atPath: HelperPaths.supportDirectory) {
            try fileManager.removeItem(atPath: HelperPaths.supportDirectory)
        }
    }

    public static func reexecAsRoot() throws -> Int32 {
        let sudo = URL(fileURLWithPath: "/usr/bin/sudo")
        let process = Process()
        process.executableURL = sudo
        let command = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        process.arguments = [command] + Array(CommandLine.arguments.dropFirst())
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func reloadLaunchDaemon() throws {
        _ = try? runLaunchctl(["bootout", "system/\(HelperPaths.label)"])
        try runLaunchctl(["bootstrap", "system", HelperPaths.plistPath])
        _ = try? runLaunchctl(["enable", "system/\(HelperPaths.label)"])
        _ = try? runLaunchctl(["kickstart", "-k", "system/\(HelperPaths.label)"])
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperError.commandFailed("launchctl \(arguments.joined(separator: " ")) failed")
        }
        return process.terminationStatus
    }
}
