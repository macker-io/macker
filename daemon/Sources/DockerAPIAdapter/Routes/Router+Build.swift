import ContainerEngine
import Foundation
import NIOCore

extension Router {
    /// `POST /build`. The context tar arrives spooled on disk (``HTTPRequest/bodyFile``).
    /// BuildKit clients send `version=2`; they are rejected with the classic-builder hint.
    func buildImage(_ request: HTTPRequest) async -> HTTPResponse {
        if let version = request.query["version"], version == "2" {
            return Self.jsonError(
                status: 400,
                message: "macker implements the classic builder only. Run `macker build`, or set DOCKER_BUILDKIT=0 for the docker CLI."
            )
        }
        if request.query["remote"]?.isEmpty == false {
            return Self.jsonError(status: 400, message: "remote build contexts are not supported")
        }
        guard let context = request.bodyFile else {
            return Self.jsonError(status: 400, message: "a build context tar is required")
        }

        let spec = Self.buildSpec(from: request)
        return Self.buildStream(await engine.buildImage(spec: spec, contextArchive: context), quiet: spec.quiet)
    }

    func pruneBuildCache(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let result = try await engine.pruneBuildCache(
                all: Self.queryFlag(request.query["all"]),
                filters: Self.parseFilters(request.query["filters"])
            )
            return Self.jsonOK(DockerBuildPruneResponse(result))
        } catch {
            return Self.engineError(error)
        }
    }

    static func buildSpec(from request: HTTPRequest) -> EngineBuildSpec {
        EngineBuildSpec(
            tags: request.queryAll["t"] ?? request.query["t"].map { [$0] } ?? [],
            dockerfile: request.query["dockerfile"] ?? BuildContext.defaultDockerfile,
            buildArgs: Self.decodeStringMap(request.query["buildargs"]),
            labels: Self.decodeStringMap(request.query["labels"]),
            target: request.query["target"],
            noCache: Self.queryFlag(request.query["nocache"]),
            pull: Self.queryFlag(request.query["pull"]),
            quiet: Self.queryFlag(request.query["q"]),
            platform: request.query["platform"],
            networkMode: request.query["networkmode"] ?? "",
            extraHosts: Self.extraHosts(request.query["extrahosts"]),
            memory: Int64(request.query["memory"] ?? "") ?? 0
        )
    }

    static func extraHosts(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Docker's build response: `{"stream":…}` lines, `{"aux":{"ID":…}}` for the image,
    /// and `{"error":…}` when a step fails.
    static func buildStream(_ events: AsyncThrowingStream<EngineBuildEvent, Error>, quiet: Bool) -> HTTPResponse {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()
        Task {
            do {
                for try await event in events {
                    switch event {
                    case .status(let text):
                        if !quiet {
                            continuation.yield(JSONBody.encodeLine(DockerBuildLine(stream: "\(text)\n")))
                        }
                    case .output(let data):
                        if !quiet, let text = String(data: data, encoding: .utf8) {
                            continuation.yield(JSONBody.encodeLine(DockerBuildLine(stream: text)))
                        }
                    case .built(let id):
                        if quiet {
                            continuation.yield(JSONBody.encodeLine(DockerBuildLine(stream: "\(id)\n")))
                        }
                        continuation.yield(JSONBody.encodeLine(DockerBuildLine(aux: .init(ID: id))))
                    }
                }
            } catch {
                continuation.yield(JSONBody.encodeLine(DockerBuildLine.error(error.localizedDescription)))
            }
            continuation.finish()
        }
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: .stream(.init(stream))
        )
    }

    static func decodeStringMap(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }
        // `docker build --build-arg FOO` with no value sends a JSON null.
        guard let decoded = try? JSONDecoder().decode([String: String?].self, from: data) else { return [:] }
        return decoded.compactMapValues { $0 }
    }
}
