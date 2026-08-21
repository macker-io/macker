import ContainerEngine
import Foundation
import NIOCore

extension Router {
    enum NamedImageRoute {
        case inspect(String)
        case history(String)
        case exportOne(String)
        case tag(String)
        case push(String)
        case delete(String)
    }

    static func matchNamedImage(method: String, path: String) -> NamedImageRoute? {
        guard path.hasPrefix("/images/") else { return nil }
        let rest = String(path.dropFirst("/images/".count))
        guard !rest.isEmpty else { return nil }

        func decode(_ name: String) -> String {
            name.removingPercentEncoding ?? name
        }

        if method == "GET", rest.hasSuffix("/json"), rest != "json" {
            return .inspect(decode(String(rest.dropLast("/json".count))))
        }
        if method == "GET", rest.hasSuffix("/history") {
            return .history(decode(String(rest.dropLast("/history".count))))
        }
        if method == "GET", rest.hasSuffix("/get"), rest != "get" {
            return .exportOne(decode(String(rest.dropLast("/get".count))))
        }
        if method == "POST", rest.hasSuffix("/tag") {
            return .tag(decode(String(rest.dropLast("/tag".count))))
        }
        if method == "POST", rest.hasSuffix("/push") {
            return .push(decode(String(rest.dropLast("/push".count))))
        }
        if method == "DELETE", !["json", "create", "search", "get", "load", "prune"].contains(rest) {
            return .delete(decode(rest))
        }
        return nil
    }

    func handleNamedImage(_ route: NamedImageRoute, request: HTTPRequest) async -> HTTPResponse {
        switch route {
        case .inspect(let name):
            return await inspectImage(name)
        case .history(let name):
            return await imageHistory(name, request: request)
        case .exportOne(let name):
            return await exportImages([name], request: request)
        case .tag(let name):
            return await tagImage(name, request: request)
        case .push(let name):
            return await pushImage(name, request: request)
        case .delete(let name):
            return await deleteImage(name, request: request)
        }
    }

    func imagesJSON(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let filters = Self.parseFilters(request.query["filters"])
            let images = try await engine.listImages(all: Self.queryFlag(request.query["all"]), filters: filters)
            return Self.jsonOK(images.map(DockerImageSummary.init))
        } catch {
            return Self.engineError(error)
        }
    }

    func createImage(_ request: HTTPRequest) async -> HTTPResponse {
        if let fromSrc = request.query["fromSrc"], !fromSrc.isEmpty {
            return Self.progressStream(
                await engine.importImage(
                    spec: EngineImportSpec(
                        source: fromSrc,
                        repo: request.query["repo"],
                        tag: request.query["tag"],
                        message: request.query["message"] ?? "",
                        changes: request.queryAll["changes"] ?? request.query["changes"].map { [$0] } ?? [],
                        platform: request.query["platform"]
                    ),
                    archive: request.bodyFile
                )
            )
        }
        guard let fromImage = request.query["fromImage"], !fromImage.isEmpty else {
            return Self.jsonError(status: 400, message: "fromImage or fromSrc query parameter is required")
        }
        // Docker API: an empty/absent tag on a name-only reference pulls all tags of the repository.
        let tag = request.query["tag"].flatMap { $0.isEmpty ? nil : $0 }
        return Self.progressStream(
            await engine.pullImage(
                name: fromImage,
                tag: tag,
                platform: request.query["platform"],
                registryAuth: request.headers["x-registry-auth"]
            )
        )
    }

    func imageHistory(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let items = try await engine.imageHistory(name: name, platform: request.query["platform"])
            return Self.jsonOK(items.map(DockerImageHistoryItem.init))
        } catch {
            return Self.engineError(error)
        }
    }

    func tagImage(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        guard let repo = request.query["repo"], !repo.isEmpty else {
            return Self.jsonError(status: 400, message: "repo query parameter is required")
        }
        do {
            try await engine.tagImage(name: name, repo: repo, tag: request.query["tag"])
            return HTTPResponse(status: 201)
        } catch {
            return Self.engineError(error)
        }
    }

    func pushImage(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        // Docker API: an empty/absent tag on a name-only reference pushes all local tags.
        Self.progressStream(
            await engine.pushImage(
                name: name,
                tag: request.query["tag"],
                platform: request.query["platform"],
                registryAuth: request.headers["x-registry-auth"]
            )
        )
    }

    func searchImages(_ request: HTTPRequest) async -> HTTPResponse {
        guard let term = request.query["term"], !term.isEmpty else {
            return Self.jsonError(status: 400, message: "term query parameter is required")
        }
        let limit = Int(request.query["limit"] ?? "") ?? 25
        do {
            return Self.jsonOK(
                try await engine.searchImages(
                    term: term,
                    limit: limit,
                    filters: Self.parseFilters(request.query["filters"])
                ).map(DockerImageSearchItem.init)
            )
        } catch {
            return Self.engineError(error)
        }
    }

    func pruneImages(_ request: HTTPRequest) async -> HTTPResponse {
        let filters = Self.parseFilters(request.query["filters"])
        let dangling = filters["dangling"]?.contains(where: { $0 == "false" || $0 == "0" }) != true
        let until = filters["until"]?.first.flatMap(Self.parseTimestamp)
        do {
            let labels = filters["label"] ?? []
            return Self.jsonOK(DockerImagePruneResponse(try await engine.pruneImages(danglingOnly: dangling, until: until, labels: labels)))
        } catch {
            return Self.engineError(error)
        }
    }

    func exportImages(_ names: [String], request: HTTPRequest) async -> HTTPResponse {
        do {
            let data = try await engine.exportImages(names: names, platform: request.query["platform"])
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            return HTTPResponse(
                status: 200,
                headers: [
                    ("Content-Type", "application/x-tar"),
                    ("Content-Disposition", "attachment; filename=images.tar"),
                ],
                body: .buffer(buffer)
            )
        } catch {
            return Self.engineError(error)
        }
    }

    func loadImages(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let references: [String]
            if let file = request.bodyFile {
                references = try await engine.loadImages(fromArchive: file)
            } else {
                references = try await engine.loadImages(from: request.body)
            }
            let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
            Task {
                for reference in references {
                    continuation.yield(JSONBody.encodeLine(DockerLoadLine(stream: "Loaded image: \(reference)\n")))
                }
                continuation.finish()
            }
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .stream(.init(stream))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    func inspectImage(_ name: String) async -> HTTPResponse {
        do {
            return Self.jsonOK(DockerImageInspect(try await engine.inspectImage(name: name)))
        } catch {
            return Self.engineError(error)
        }
    }

    func deleteImage(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let force = Self.queryFlag(request.query["force"])
            let noPrune = Self.queryFlag(request.query["noprune"])
            return Self.jsonOK(try await engine.deleteImage(name: name, force: force, noPrune: noPrune).map(DockerImageDeleteItem.init))
        } catch {
            return Self.engineError(error)
        }
    }

    func commitContainer(_ request: HTTPRequest) async -> HTTPResponse {
        guard let container = request.query["container"], !container.isEmpty else {
            return Self.jsonError(status: 400, message: "container query parameter is required")
        }
        var config: EngineCommitConfig?
        if !request.body.isEmpty {
            do {
                config = try JSONDecoder().decode(DockerCommitRequest.self, from: request.body).engineConfig
            } catch {
                return Self.jsonError(status: 400, message: "invalid commit config: \(error.localizedDescription)")
            }
        }
        let spec = EngineCommitSpec(
            repo: request.query["repo"],
            tag: request.query["tag"],
            comment: request.query["comment"] ?? "",
            author: request.query["author"] ?? "",
            changes: request.queryAll["changes"] ?? request.query["changes"].map { [$0] } ?? [],
            config: config
        )
        do {
            let id = try await engine.commitContainer(container, spec: spec)
            return HTTPResponse(
                status: 201,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerCommitResponse(Id: id)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    static func progressStream(_ events: AsyncThrowingStream<ImagePullEvent, Error>) -> HTTPResponse {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        Task {
            do {
                for try await event in events {
                    continuation.yield(JSONBody.encodeLine(DockerProgressLine(event)))
                }
            } catch {
                continuation.yield(JSONBody.encodeLine(DockerProgressLine.error(error.localizedDescription)))
            }
            continuation.finish()
        }
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: .stream(.init(stream))
        )
    }
}
