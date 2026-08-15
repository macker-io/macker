import ContainerEngine
import Foundation

extension Router {
    enum NamedNetworkRoute {
        case inspect(String)
        case delete(String)
        case connect(String)
        case disconnect(String)
    }

    private static let reservedNetworkNames: Set<String> = ["create", "prune"]

    static func matchNamedNetwork(method: String, path: String) -> NamedNetworkRoute? {
        guard path.hasPrefix("/networks/") else { return nil }
        let rest = String(path.dropFirst("/networks/".count))
        guard !rest.isEmpty else { return nil }

        func decode(_ name: String) -> String {
            name.removingPercentEncoding ?? name
        }

        if let slash = rest.lastIndex(of: "/") {
            let id = decode(String(rest[..<slash]))
            let action = String(rest[rest.index(after: slash)...])
            if reservedNetworkNames.contains(id) { return nil }
            switch (method, action) {
            case ("POST", "connect"):
                return .connect(id)
            case ("POST", "disconnect"):
                return .disconnect(id)
            default:
                return nil
            }
        }

        let name = decode(rest)
        guard !reservedNetworkNames.contains(name) else { return nil }
        switch method {
        case "GET":
            return .inspect(name)
        case "DELETE":
            return .delete(name)
        default:
            return nil
        }
    }

    func handleNamedNetwork(_ route: NamedNetworkRoute, request: HTTPRequest) async -> HTTPResponse {
        switch route {
        case .inspect(let name):
            return await inspectNetwork(name)
        case .delete(let name):
            return await deleteNetwork(name)
        case .connect(let name):
            return await connectNetwork(name, request: request)
        case .disconnect(let name):
            return await disconnectNetwork(name, request: request)
        }
    }

    func listNetworks(_ request: HTTPRequest) async -> HTTPResponse {
        let filters = Self.parseFilters(request.query["filters"])
        let networks = await engine.listNetworks(filters: filters).map(DockerNetwork.init)
        return Self.jsonOK(networks)
    }

    func createNetwork(_ request: HTTPRequest) async -> HTTPResponse {
        let body: DockerCreateNetworkRequest
        if request.body.isEmpty {
            body = DockerCreateNetworkRequest(Name: nil, Driver: nil, Internal: nil, Labels: nil, IPAM: nil)
        } else {
            do {
                body = try JSONDecoder().decode(DockerCreateNetworkRequest.self, from: request.body)
            } catch {
                return Self.jsonError(status: 400, message: "invalid network config: \(error.localizedDescription)")
            }
        }

        let ipam = body.IPAM?.Config?.first
        do {
            let created = try await engine.createNetwork(
                EngineNetworkCreateSpec(
                    name: body.Name,
                    driver: body.Driver ?? "bridge",
                    labels: body.Labels ?? [:],
                    subnet: ipam?.Subnet,
                    gateway: ipam?.Gateway,
                    internalNetwork: body.Internal ?? false
                )
            )
            return HTTPResponse(
                status: 201,
                headers: [("Content-Type", "application/json")],
                body: .buffer(JSONBody.encode(DockerCreateNetworkResponse(Id: created.network.id, Warning: "")))
            )
        } catch {
            return Self.engineError(error)
        }
    }

    func pruneNetworks(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let result = try await engine.pruneNetworks(filters: Self.parseFilters(request.query["filters"]))
            return Self.jsonOK(DockerNetworkPruneResponse(NetworksDeleted: result.deleted))
        } catch {
            return Self.engineError(error)
        }
    }

    private func inspectNetwork(_ name: String) async -> HTTPResponse {
        do {
            return Self.jsonOK(DockerNetwork(try await engine.inspectNetwork(name)))
        } catch {
            return Self.engineError(error)
        }
    }

    private func deleteNetwork(_ name: String) async -> HTTPResponse {
        do {
            try await engine.deleteNetwork(name)
            return HTTPResponse(status: 204)
        } catch {
            return Self.engineError(error)
        }
    }

    private func connectNetwork(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        let body: DockerConnectNetworkRequest
        do {
            body = try JSONDecoder().decode(DockerConnectNetworkRequest.self, from: request.body)
        } catch {
            return Self.jsonError(status: 400, message: "invalid connect config: \(error.localizedDescription)")
        }
        guard let container = body.Container, !container.isEmpty else {
            return Self.jsonError(status: 400, message: "container is required")
        }
        do {
            try await engine.connectNetwork(
                name,
                spec: EngineNetworkConnectSpec(container: container, aliases: body.EndpointConfig?.Aliases ?? [])
            )
            return HTTPResponse(status: 200)
        } catch {
            return Self.engineError(error)
        }
    }

    private func disconnectNetwork(_ name: String, request: HTTPRequest) async -> HTTPResponse {
        let body: DockerDisconnectNetworkRequest
        do {
            body = try JSONDecoder().decode(DockerDisconnectNetworkRequest.self, from: request.body)
        } catch {
            return Self.jsonError(status: 400, message: "invalid disconnect config: \(error.localizedDescription)")
        }
        guard let container = body.Container, !container.isEmpty else {
            return Self.jsonError(status: 400, message: "container is required")
        }
        do {
            try await engine.disconnectNetwork(name, container: container, force: body.Force ?? false)
            return HTTPResponse(status: 200)
        } catch {
            return Self.engineError(error)
        }
    }
}
