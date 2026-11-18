import Dispatch
import Foundation
import MackerTransport

nonisolated struct DesktopDaemonClient: Sendable {
    let socketPath: String

    private struct Version: Decodable {
        let Version: String
        let Platform: Platform
        struct Platform: Decodable { let Name: String }
    }

    private struct VolumeList: Decodable {
        let Volumes: [DaemonSnapshot.Volume]?
    }

    private struct APIError: Decodable { let message: String }

    private struct RequestError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func local(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let override = environment["MACKER_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = String(override.trimmingPrefix("unix://"))
        if path.hasPrefix("/") { return Self(socketPath: path) }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(socketPath: support.appending(path: "io.macker.daemon/macker.sock").path)
    }

    struct Activity: Decodable, Equatable, Sendable {
        let runningContainers: Int
        let activeBuilds: Int
    }

    func activity() async throws -> Activity? {
        try await offMain {
            let response = try response("/macker/status")
            // Older Macker daemons do not expose build status.
            return response.statusCode == 404 ? nil : try decode(response)
        }
    }

    func snapshot() async throws -> DaemonSnapshot {
        try await offMain { try loadSnapshot() }
    }

    private func offMain<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        // Blocking Unix I/O must not occupy the main actor or the cooperative executor.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    private func loadSnapshot() throws -> DaemonSnapshot {
        let version: Version = try get("/version")
        guard version.Platform.Name == "macker" else {
            throw RequestError(message: "The selected socket does not belong to mackerd.")
        }
        return try DaemonSnapshot(
            version: version.Version,
            containers: get("/v1.41/containers/json?all=1"),
            images: get("/v1.41/images/json?all=1"),
            networks: get("/v1.41/networks"),
            volumes: (get("/v1.41/volumes") as VolumeList).Volumes ?? []
        )
    }

    enum ImageOperation: Sendable {
        case pull(reference: String, platform: String?)
        case load(URL)
        case importRootfs(URL, repository: String, tag: String, platform: String?)
        case export(references: [String], platform: String?, destination: URL)
        case delete(String)

        var title: String {
            switch self {
            case .pull: "Pulling Image"
            case .load: "Loading Archive"
            case .importRootfs: "Importing Filesystem"
            case .export: "Exporting Image"
            case .delete: "Deleting Image"
            }
        }
    }

    struct ImageProgress: Sendable {
        let message: String
        let fraction: Double?
    }

    private struct ProgressLine: Decodable {
        struct Detail: Decodable { let current: Int64; let total: Int64 }
        let status: String?
        let stream: String?
        let progressDetail: Detail?
        let error: String?
    }

    func perform(_ operation: ImageOperation, onProgress: @escaping @Sendable (ImageProgress) -> Void) async throws {
        try await offMain {
            let version: Version = try get("/version")
            guard version.Platform.Name == "macker" else {
                throw RequestError(message: "The selected socket does not belong to mackerd.")
            }
            switch operation {
            case .pull(let reference, let platform):
                // A name-only reference without a tag means “all tags” to the Engine API.
                let leaf = reference.split(separator: "/").last ?? ""
                let tag = reference.contains("@") || leaf.contains(":") ? nil : "latest"
                try transferImage(path: Self.path("/images/create", [("fromImage", reference), ("tag", tag), ("platform", platform)]), onProgress: onProgress)
            case .load(let archive):
                try transferImage(path: "/v1.41/images/load", archive: archive, onProgress: onProgress)
            case .importRootfs(let archive, let repository, let tag, let platform):
                let path = Self.path("/images/create", [
                    ("fromSrc", "-"), ("repo", repository), ("tag", tag), ("platform", platform),
                ])
                try transferImage(path: path, archive: archive, onProgress: onProgress)
            case .export(let references, let platform, let destination):
                try exportImage(references: references, platform: platform, destination: destination)
            case .delete(let reference):
                var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: 30)
                defer { reader.close() }
                let segment = reference.addingPercentEncoding(withAllowedCharacters: Self.encodedValue) ?? ""
                try reader.send(method: "DELETE", path: "/v1.41/images/\(segment)", body: nil)
                let head = try reader.readHead()
                try requireSuccess(reader: &reader, head: head)
            }
        }
    }

    private static let encodedValue = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func path(_ path: String, _ arguments: [(String, String?)]) -> String {
        let parameters = arguments.compactMap { name, value -> String? in
            guard let value, let encoded = value.addingPercentEncoding(withAllowedCharacters: encodedValue) else { return nil }
            return "\(name)=\(encoded)"
        }
        return "/v1.41\(path)?\(parameters.joined(separator: "&"))"
    }

    private func requireSuccess(reader: inout HTTPReader, head: (statusCode: Int, headers: [String: String])) throws {
        guard !(200..<300).contains(head.statusCode) else { return }
        let body = try reader.readBody(status: head.statusCode, headers: head.headers)
        let message = (try? JSONDecoder().decode(APIError.self, from: body))?.message
        throw RequestError(message: message ?? "Daemon request failed (HTTP \(head.statusCode)).")
    }

    private func transferImage(
        path: String, archive: URL? = nil, onProgress: (ImageProgress) -> Void
    ) throws {
        var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: 300)
        defer { reader.close() }
        if let archive {
            try reader.send(method: "POST", path: path, bodyFile: archive, contentType: "application/x-tar")
        } else {
            try reader.send(method: "POST", path: path, body: nil)
        }
        let head = try reader.readHead()
        try requireSuccess(reader: &reader, head: head)

        let decoder = JSONDecoder()
        var errorMessage: String?
        var lastProgress = Date.distantPast
        var lastMessage: String?
        try reader.readBodyLines(status: head.statusCode, headers: head.headers) { line in
            guard let decoded = try? decoder.decode(ProgressLine.self, from: Data(line.utf8)) else { return }
            if let error = decoded.error { errorMessage = error }
            guard let message = decoded.status ?? decoded.stream?.trimmingCharacters(in: .newlines),
                message != lastMessage || Date().timeIntervalSince(lastProgress) >= 0.15 else { return }
            let fraction = decoded.progressDetail.flatMap { detail in
                detail.total > 0 ? min(1, max(0, Double(detail.current) / Double(detail.total))) : nil
            }
            lastProgress = Date()
            lastMessage = message
            onProgress(ImageProgress(message: message, fraction: fraction))
        }
        if let errorMessage { throw RequestError(message: errorMessage) }
    }

    private func exportImage(references: [String], platform: String?, destination: URL) throws {
        let path = Self.path("/images/get", references.map { ("names", Optional($0)) } + [("platform", platform)])
        var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: 300)
        defer { reader.close() }
        try reader.send(method: "GET", path: path, body: nil)
        let head = try reader.readHead()
        try requireSuccess(reader: &reader, head: head)
        // Publish the completed archive atomically; do not overwrite a good file on transfer failure.
        let temporary = destination.deletingLastPathComponent().appending(path: ".macker-\(UUID()).tar")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RequestError(message: "Unable to write the export archive.")
        }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        try reader.readBodyStreaming(status: head.statusCode, headers: head.headers) { try file.write(contentsOf: $0) }
        try file.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func get<Value: Decodable>(_ path: String) throws -> Value {
        try decode(response(path))
    }

    private func response(_ path: String) throws -> (statusCode: Int, body: Data) {
        var reader = try HTTPReader(socketPath: socketPath, timeoutSeconds: 3)
        defer { reader.close() }
        try reader.send(method: "GET", path: path, body: nil)
        let head = try reader.readHead()
        let body = try reader.readBody(status: head.statusCode, headers: head.headers)
        return (head.statusCode, body)
    }

    private func decode<Value: Decodable>(_ response: (statusCode: Int, body: Data)) throws -> Value {
        let decoder = JSONDecoder()
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? decoder.decode(APIError.self, from: response.body))?.message
            throw RequestError(message: message ?? "Daemon request failed (HTTP \(response.statusCode)).")
        }
        return try decoder.decode(Value.self, from: response.body)
    }
}
