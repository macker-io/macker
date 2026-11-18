import ContainerEngine
import Foundation
import NIOCore

extension Router {
    /// `/distribution/{name}/json`. `name` may contain slashes. `?manifest=1` returns the raw manifest.
    static func distributionName(_ path: String) -> String? {
        guard path.hasPrefix("/distribution/"), path.hasSuffix("/json"), path != "/distribution/json" else { return nil }
        let rest = path.dropFirst("/distribution/".count).dropLast("/json".count)
        let decoded = String(rest).removingPercentEncoding ?? String(rest)
        return decoded.isEmpty ? nil : decoded
    }

    func distributionInspect(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            let inspect = try await engine.distributionInspect(
                name: name,
                registryAuth: request.headers["x-registry-auth"],
                insecure: Self.queryFlag(request.query["insecure"])
            )
            if Self.queryFlag(request.query["manifest"]) {
                var buffer = ByteBuffer()
                buffer.writeBytes(inspect.manifest)
                return HTTPResponse(
                    status: 200,
                    headers: [("Content-Type", inspect.mediaType.isEmpty ? "application/json" : inspect.mediaType)],
                    body: .buffer(buffer)
                )
            }
            return Self.jsonOK(DockerDistributionInspect(inspect))
        } catch {
            return Self.engineError(error)
        }
    }
}

struct DockerDistributionInspect: Encodable, Sendable {
    var Descriptor: ImageDescriptor
    var Platforms: [ImagePlatform]

    struct ImageDescriptor: Encodable, Sendable {
        var mediaType: String
        var digest: String
        var size: Int64
    }

    struct ImagePlatform: Encodable, Sendable {
        var architecture: String
        var os: String
        var variant: String
    }

    init(_ inspect: EngineDistributionInspect) {
        Descriptor = ImageDescriptor(mediaType: inspect.mediaType, digest: inspect.digest, size: inspect.size)
        Platforms = inspect.platforms.map {
            ImagePlatform(architecture: $0.architecture, os: $0.os, variant: $0.variant)
        }
    }
}
