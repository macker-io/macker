import Foundation

extension Router {
    /// Plugin v2 API. The list is empty; nothing can be installed on this runtime.
    static func pluginResponse(method: String, path: String, query: [String: String]) -> HTTPResponse? {
        guard path == "/plugins" || path.hasPrefix("/plugins/") else { return nil }

        if path == "/plugins" {
            guard method == "GET" else { return nil }
            return jsonOK([String]())
        }
        if path == "/plugins/privileges", method == "GET" {
            guard let remote = query["remote"], !remote.isEmpty else {
                return jsonError(status: 400, message: "remote query parameter is required")
            }
            return jsonError(status: 501, message: "plugins are not implemented")
        }
        if (path == "/plugins/pull" || path == "/plugins/create"), method == "POST" {
            return jsonError(status: 501, message: "plugins are not implemented")
        }

        let rest = String(path.dropFirst("/plugins/".count))
        func decode(_ name: String) -> String {
            name.removingPercentEncoding ?? name
        }
        if method == "GET", rest.hasSuffix("/json"), rest != "json" {
            let name = decode(String(rest.dropLast("/json".count)))
            return jsonError(status: 404, message: "plugin \"\(name)\" not found")
        }
        let actions = ["/enable", "/disable", "/push", "/set", "/upgrade"]
        if method == "POST", let suffix = actions.first(where: { rest.hasSuffix($0) }), rest.count > suffix.count {
            let name = decode(String(rest.dropLast(suffix.count)))
            return jsonError(status: 404, message: "plugin \"\(name)\" not found")
        }
        if method == "DELETE", !rest.isEmpty, !["privileges", "pull", "create"].contains(rest) {
            return jsonError(status: 404, message: "plugin \"\(decode(rest))\" not found")
        }
        return nil
    }
}
