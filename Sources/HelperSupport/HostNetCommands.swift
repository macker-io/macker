import Foundation

/// `ifconfig` / `route` used by the helper (always) and by a root `mackerd` fallback.
public enum HostNetCommands: Sendable {
    public static func configure(interface: String, address: String, peer: String, prefix: Int) throws {
        try run(
            "/sbin/ifconfig",
            [interface, "inet", address, peer, "netmask", HelperNetText.netmask(prefix: prefix), "up"]
        )
        // Point-to-point utun still ARPs if the netmask makes the subnet on-link.
        try run("/sbin/ifconfig", [interface, "-arp"])
    }

    public static func addAddress(interface: String, address: String, peer: String, prefix: Int) throws {
        try run(
            "/sbin/ifconfig",
            [interface, "inet", address, peer, "netmask", HelperNetText.netmask(prefix: prefix), "alias"]
        )
    }

    public static func addRoute(interface: String, subnet: String) throws {
        try run("/sbin/route", ["-n", "add", "-net", subnet, "-interface", interface])
    }

    public static func deleteRoute(subnet: String) throws {
        try run("/sbin/route", ["-n", "delete", "-net", subnet])
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if detail.lowercased().contains("file exists") {
                return
            }
            throw HelperError.commandFailed(
                "\(path) \(arguments.joined(separator: " ")) failed"
                    + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
    }
}
