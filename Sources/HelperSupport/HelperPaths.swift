import Foundation

/// On-disk locations for the privileged host-route helper.
public enum HelperPaths: Sendable {
    public static let label = "io.macker.helper"
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/io.macker.helper"
    public static let plistPath = "/Library/LaunchDaemons/io.macker.helper.plist"
    public static let socketPath = "/var/run/io.macker.helper.sock"
    public static let supportDirectory = "/Library/Application Support/io.macker.helper"
    public static let allowedUIDsPath = supportDirectory + "/allowed-uids"
    public static let logPath = "/var/log/io.macker.helper.log"

    public static var installedBinaryURL: URL {
        URL(fileURLWithPath: installedBinaryPath)
    }

    /// UIDs allowed to configure routes. Written by `macker helper install`.
    public static func loadAllowedUIDs(from path: String = allowedUIDsPath) -> Set<uid_t> {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var uids: Set<uid_t> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = uid_t(trimmed) {
                uids.insert(value)
            }
        }
        return uids
    }

    public static func writeAllowedUIDs(
        _ uids: Set<uid_t>,
        to path: String = allowedUIDsPath,
        fileManager: FileManager = .default
    ) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = uids.sorted().map(String.init).joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: path
        )
    }
}
