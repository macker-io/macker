import Foundation

extension Router {
    /// Same text a non-manager dockerd returns for Swarm object APIs.
    static let swarmManagerMessage =
        "This node is not a swarm manager. Use \"docker swarm init\" or \"docker swarm join\" to connect this node to swarm and try again."

    /// Swarm, node, service, task, secret, and config routes.
    ///
    /// Reads and object mutations match a daemon that has not joined a swarm (503).
    /// `POST /swarm/init` and `POST /swarm/join` are the calls that would create
    /// membership; those stay 501 because this runtime does not implement Swarm.
    static func swarmResponse(method: String, path: String) -> HTTPResponse? {
        guard let root = path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init),
            ["swarm", "nodes", "services", "tasks", "secrets", "configs"].contains(root)
        else {
            return nil
        }
        if method == "POST", path == "/swarm/init" || path == "/swarm/join" {
            return jsonError(status: 501, message: "swarm is not implemented")
        }
        return jsonError(status: 503, message: swarmManagerMessage)
    }
}
