import ArgumentParser
import ContainerEngine
import Foundation

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether the Macker daemon is running."
    )

    func run() throws {
        let socket = DaemonAPI.socket
        print("Socket: \(socket)")

        guard FileManager.default.fileExists(atPath: socket) else {
            print("Daemon: stopped")
            print("Detail: socket file is missing")
            throw ExitCode(1)
        }

        let ping: UnixHTTPClient.Response
        do {
            ping = try DaemonAPI.get("/_ping")
        } catch {
            print("Daemon: stopped")
            print("Detail: \(error.localizedDescription)")
            throw ExitCode(1)
        }

        let pingBody = String(data: ping.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ping.statusCode == 200 else {
            print("Daemon: unresponsive")
            print("Ping:   HTTP \(ping.statusCode) \(pingBody)")
            throw ExitCode(1)
        }

        print("Daemon: running")
        print("Ping:   \(pingBody.isEmpty ? "OK" : pingBody)")

        if let info = try? DaemonAPI.decode(InfoSnippet.self, from: DaemonAPI.get("/info")) {
            if let id = info.ID { print("ID:     \(id)") }
            if let version = info.ServerVersion { print("API:    \(version)") }
            print("Containers: \(info.Containers ?? 0) (\(info.ContainersRunning ?? 0) running)")
            print("Images:     \(info.Images ?? 0)")
        }
    }
}

private struct InfoSnippet: Decodable {
    var ID: String?
    var Containers: Int?
    var ContainersRunning: Int?
    var Images: Int?
    var ServerVersion: String?
}
