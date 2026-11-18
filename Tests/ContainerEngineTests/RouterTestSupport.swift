import Foundation
import NIOCore
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

enum RouterTestSupport {
    static func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Any? = nil,
        bodyFile: URL? = nil
    ) throws -> HTTPRequest {
        let data: Data
        if let body = body as? Data {
            data = body
        } else if let body {
            data = try JSONSerialization.data(withJSONObject: body)
        } else {
            data = Data()
        }
        return HTTPRequest(method: method, path: path, query: query, body: data, bodyFile: bodyFile)
    }

    static func filters(_ dict: [String: [String]]) throws -> String {
        String(decoding: try JSONEncoder().encode(dict), as: UTF8.self)
    }

    static func data(_ response: HTTPResponse) -> Data {
        switch response.body {
        case .buffer(var buffer):
            return Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .none, .stream, .hijack, .upgrade:
            return Data()
        }
    }

    static func text(_ response: HTTPResponse) -> String {
        String(data: data(response), encoding: .utf8) ?? ""
    }

    static func json(_ response: HTTPResponse) throws -> Any {
        try JSONSerialization.jsonObject(with: data(response))
    }

    static func jsonObject(_ response: HTTPResponse) throws -> [String: Any] {
        guard let object = try json(response) as? [String: Any] else {
            throw EngineError.invalidArgument("expected JSON object")
        }
        return object
    }

    static func jsonArray(_ response: HTTPResponse) throws -> [[String: Any]] {
        guard let array = try json(response) as? [[String: Any]] else {
            throw EngineError.invalidArgument("expected JSON array")
        }
        return array
    }

    static func message(_ response: HTTPResponse) throws -> String? {
        try jsonObject(response)["message"] as? String
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }

    static func header(_ response: HTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    static func importTagged(
        _ engine: EngineManager,
        repo: String,
        tag: String = "latest",
        hello: String? = nil
    ) async throws {
        try await TemporaryDirectory.with("macker-router-import") { work in
            _ = try await collectDigest(
                await engine.importImage(
                    spec: EngineImportSpec(source: "-", repo: repo, tag: tag),
                    archive: try pack(hello: hello ?? "\(repo)\n", in: work)
                )
            )
        }
    }

    static func createContainer(
        _ router: Router,
        name: String? = nil,
        image: String = "alpine:latest",
        labels: [String: String] = [:]
    ) async throws -> String {
        var query: [String: String] = [:]
        if let name { query["name"] = name }
        var body: [String: Any] = ["Image": image]
        if !labels.isEmpty { body["Labels"] = labels }
        let created = await router.handle(try request("POST", "/containers/create", query: query, body: body))
        guard created.status == 201, let id = try jsonObject(created)["Id"] as? String else {
            throw EngineError.invalidArgument("create failed: \(text(created))")
        }
        return id
    }
}

func withRouter(_ body: (Router, EngineManager) async throws -> Void) async throws {
    try await withEngine { engine in
        try await body(Router(engine: engine), engine)
    }
}
