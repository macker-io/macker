import Foundation
import Logging
import Testing
@testable import CliCore
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct SocketDaemonTests {
    @Test func unixSocketServesPingCreateAndQuery() async throws {
        try await withSocketServer { socket, engine in
            try await importAlpine(engine)

            let ping = try daemonRequest("GET", "/v1.41/_ping", socket: socket)
            #expect(ping.statusCode == 200)
            #expect(String(data: ping.body, encoding: .utf8) == "OK")

            let head = try daemonRequest("HEAD", "/_ping", socket: socket)
            #expect(head.statusCode == 200)
            #expect(head.body.isEmpty)

            let created = try daemonRequest(
                "POST",
                "/v1.41/containers/create?name=web",
                socket: socket,
                json: ["Image": "alpine:latest"]
            )
            #expect(created.statusCode == 201)
            #expect((try jsonObject(created.body)["Id"] as? String)?.count == 64)

            let listed = try daemonRequest("GET", "/v1.41/containers/json?all=1", socket: socket)
            #expect(listed.statusCode == 200)
            let names = try jsonArray(listed.body).compactMap { $0["Names"] as? [String] }
            #expect(names.contains(["/web"]))

            let volume = try daemonRequest(
                "POST",
                "/v1.41/volumes/create",
                socket: socket,
                json: ["Name": "data"]
            )
            #expect(volume.statusCode == 201)
            #expect(try jsonObject(volume.body)["Name"] as? String == "data")
        }
    }
}

private func daemonRequest(
    _ method: String,
    _ path: String,
    socket: String,
    json: [String: Any]? = nil
) throws -> UnixHTTPClient.Response {
    try UnixHTTPClient.request(
        method: method,
        path: path,
        socketPath: socket,
        body: json.map { try JSONSerialization.data(withJSONObject: $0) },
        contentType: "application/json"
    )
}

private func withSocketServer(_ body: (String, EngineManager) async throws -> Void) async throws {
    try await TemporaryDirectory.with("macker-socket-daemon") { dir in
        // sockaddr_un on macOS is 104 bytes; the temp store path is too long for the socket.
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("mks-\(UUID().uuidString.prefix(8)).sock").path
        defer { try? FileManager.default.removeItem(atPath: socket) }
        let engine = try EngineManager(storePath: dir)
        var logger = Logger(label: "io.macker.test")
        logger.logLevel = .error
        let server = SocketServer(socketPath: socket, engine: engine, logger: logger)
        let task = Task { try await server.start() }
        let result: Result<Void, Error>
        do {
            try await waitForSocket(socket)
            try await body(socket, engine)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await server.stop()
        _ = await task.result
        try result.get()
    }
}

private func waitForSocket(_ path: String) async throws {
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: path) { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw EngineError.runtimeUnavailable("socket did not appear: \(path)")
}

private func importAlpine(_ engine: EngineManager) async throws {
    try await TemporaryDirectory.with("macker-sock-import") { work in
        let root = work.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("sock\n".utf8).write(to: root.appendingPathComponent("hello.txt"))
        let tar = work.appendingPathComponent("rootfs.tar")
        try TarArchive.createContents(of: root, into: tar)
        for try await _ in await engine.importImage(
            spec: EngineImportSpec(source: "-", repo: "alpine", tag: "latest"),
            archive: tar
        ) {}
    }
}
