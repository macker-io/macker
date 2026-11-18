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

    /// `docker run` blocks on the `wait` response header before it calls `start`; the
    /// header must reach the client while the body is still pending.
    @Test func waitHeaderIsFlushedBeforeTheContainerExits() async throws {
        try await withSocketServer { socket, engine in
            try await importAlpine(engine)
            let created = try daemonRequest("POST", "/containers/create?name=w", socket: socket, json: ["Image": "alpine:latest"])
            #expect(created.statusCode == 201)

            let fd = try connectUnix(socket)
            defer { close(fd) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let request = "POST /v1.44/containers/w/wait?condition=next-exit HTTP/1.1\r\nHost: d\r\nContent-Length: 0\r\n\r\n"
            _ = request.withCString { write(fd, $0, strlen($0)) }
            var head = Data()
            var byte = [UInt8](repeating: 0, count: 1024)
            while !String(decoding: head, as: UTF8.self).contains("\r\n\r\n") {
                let n = read(fd, &byte, byte.count)
                guard n > 0 else { break }
                head.append(contentsOf: byte.prefix(n))
            }
            let text = String(decoding: head, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 200"))
            #expect(!text.contains("StatusCode"))

            let removed = try daemonRequest("DELETE", "/containers/w", socket: socket)
            #expect(removed.statusCode == 204)
            var rest = Data()
            while !String(decoding: rest, as: UTF8.self).contains("StatusCode") {
                let n = read(fd, &byte, byte.count)
                guard n > 0 else { break }
                rest.append(contentsOf: byte.prefix(n))
            }
            #expect(String(decoding: rest, as: UTF8.self).contains(#"{"StatusCode":0}"#))
        }
    }
}

private func connectUnix(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        _ = path.withCString { strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count - 1) }
    }
    let ok = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard ok == 0 else {
        close(fd)
        throw EngineError.runtimeUnavailable("connect \(path) failed")
    }
    return fd
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
