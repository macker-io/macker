import ContainerEngine
import Foundation

extension Router {
    enum NamedVolumeRoute {
        case inspect(String)
        case delete(String)
    }

    private static let reservedVolumeNames: Set<String> = ["create", "prune"]

    static func matchNamedVolume(method: String, path: String) -> NamedVolumeRoute? {
        guard path.hasPrefix("/volumes/") else { return nil }
        let rest = String(path.dropFirst("/volumes/".count))
        guard !rest.isEmpty, !reservedVolumeNames.contains(rest) else { return nil }
        let name = rest.removingPercentEncoding ?? rest
        switch method {
        case "GET":
            return .inspect(name)
        case "DELETE":
            return .delete(name)
        default:
            return nil
        }
    }

    func handleNamedVolume(_ route: NamedVolumeRoute, request: HTTPRequest) async -> HTTPResponse {
        switch route {
        case .inspect(let name):
            return await inspectVolume(name)
        case .delete(let name):
            return await deleteVolume(name, request: request)
        }
    }

    func listVolumes(_ request: HTTPRequest) async -> HTTPResponse {
        let filters = Self.parseFilters(request.query["filters"])
        let volumes = await engine.listVolumes(filters: filters).map { DockerVolume($0) }
        return HTTPResponse(
            status: 200,
            headers: [("Content-Type", "application/json")],
            body: .buffer(JSONBody.encode(DockerVolumeListResponse(Volumes: volumes, Warnings: [])))
        )
    }

    func createVolume(_ request: HTTPRequest) async -> HTTPResponse {
        let body: DockerCreateVolumeRequest
        if request.body.isEmpty {
            body = DockerCreateVolumeRequest()
        } else {
            do {
                body = try JSONDecoder().decode(DockerCreateVolumeRequest.self, from: request.body)
            } catch {
                return Self.jsonError(status: 400, message: "invalid volume config: \(error.localizedDescription)")
            }
        }

        do {
            let created = try await engine.createVolume(
                EngineVolumeCreateSpec(
                    name: body.Name,
                    driver: body.Driver ?? "local",
                    labels: body.Labels ?? [:],
                    options: body.DriverOpts ?? [:]
                )
            )
            return HTTPResponse(
                status: 201,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerVolume(created)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    func pruneVolumes(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let result = try await engine.pruneVolumes(filters: Self.parseFilters(request.query["filters"]))
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerVolumePruneResponse(
                    VolumesDeleted: result.deleted,
                    SpaceReclaimed: result.spaceReclaimed
                )))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func inspectVolume(_ name: String) async -> HTTPResponse {
        do {
            let volume = try await engine.inspectVolume(name)
            return HTTPResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerVolume(volume)))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    private func deleteVolume(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        do {
            try await engine.deleteVolume(name, force: Self.queryFlag(request.query["force"]))
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }
}
