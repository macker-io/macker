import ArgumentParser
import Foundation

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the Macker / Docker-compatible API version."
    )

    func run() throws {
        let version = try DaemonAPI.decode(VersionInfo.self, from: DaemonAPI.get("/version"))
        print("Client: \(Invocation.commandName)")
        print(" Version:    \(DaemonAPI.clientVersion)")
        print(" API:        \(DaemonAPI.apiVersion)")
        print("Server:")
        print(" Version:    \(version.Version)")
        print(" API:        \(version.ApiVersion)")
        print(" OS/Arch:    \(version.Os)/\(version.Arch)")
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display system-wide information.")

    func run() throws {
        try DaemonAPI.printJSON(try DaemonAPI.requireOK(DaemonAPI.get("/info")).body)
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get real time events from the server.")

    @Option(name: .shortAndLong, help: "Filter output based on conditions provided.")
    var filter: [String] = []

    @Option(help: "Show all events created since timestamp.")
    var since: String?

    @Option(help: "Stream events until this timestamp.")
    var until: String?

    func run() throws {
        var query: [String] = []
        if let since { query.append("since=\(DaemonAPI.query(since))") }
        if let until { query.append("until=\(DaemonAPI.query(until))") }
        if !filter.isEmpty {
            query.append("filters=\(DaemonAPI.query(try Self.encodeFilters(filter)))")
        }
        let path = query.isEmpty ? "/events" : "/events?\(query.joined(separator: "&"))"
        let status = try DaemonAPI.streamLines(method: "GET", path: path, timeoutSeconds: nil) { line in
            print(line)
        }
        if status >= 400 {
            throw CLIError.http("events failed with HTTP \(status)")
        }
    }

    private static func encodeFilters(_ specs: [String]) throws -> String {
        var map: [String: [String]] = [:]
        for spec in specs {
            guard let eq = spec.firstIndex(of: "=") else {
                throw CLIError.http("Invalid filter '\(spec)'")
            }
            let key = String(spec[..<eq])
            let value = String(spec[spec.index(after: eq)...])
            map[key, default: []].append(value)
        }
        let data = try JSONEncoder().encode(map)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

struct SystemDf: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "df", abstract: "Show docker disk usage.")

    func run() throws {
        try DaemonAPI.printJSON(try DaemonAPI.requireOK(DaemonAPI.get("/system/df")).body)
    }
}

struct SystemGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "Manage Macker.",
        subcommands: [SystemDf.self, Info.self, Events.self]
    )
}

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build an image from a Dockerfile (not implemented)."
    )

    @Argument(help: "Build context (unused).")
    var path: String?

    func run() throws {
        throw CLIError.http("image build is not implemented")
    }
}

private struct VersionInfo: Decodable {
    var Version: String
    var ApiVersion: String
    var Os: String
    var Arch: String
}
