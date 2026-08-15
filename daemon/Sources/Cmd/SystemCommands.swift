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

    func run() throws {
        let status = try DaemonAPI.streamLines(method: "GET", path: "/events", timeoutSeconds: nil) { line in
            print(line)
        }
        if status >= 400 {
            throw CLIError.http("events failed with HTTP \(status)")
        }
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
