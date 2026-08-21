import Foundation

/// Decode-side of inspect `NetworkSettings.Ports` for `macker port`.
/// Lives here because the CLI target cannot import DockerAPIAdapter (NIO).
public enum DockerPortMapping {
    struct Host: Equatable, Sendable, Decodable {
        var ip: String
        var port: String

        enum CodingKeys: String, CodingKey {
            case ip = "HostIp"
            case port = "HostPort"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ip = try container.decodeIfPresent(String.self, forKey: .ip) ?? ""
            port = try container.decodeIfPresent(String.self, forKey: .port) ?? ""
        }

        func binding(inspectKey: String) -> EnginePortBinding? {
            guard let exposed = try? EnginePortBinding.parseExposed(inspectKey) else { return nil }
            return EnginePortBinding(
                hostIP: ip,
                hostPort: Int(port) ?? 0,
                containerPort: exposed.containerPort,
                protocolName: exposed.protocolName
            )
        }
    }

    public struct Inspect: Decodable {
        var NetworkSettings: Settings

        struct Settings: Decodable {
            var Ports: [String: [Host]?]?
        }

        enum CodingKeys: String, CodingKey {
            case NetworkSettings
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            NetworkSettings = try container.decode(Settings.self, forKey: .NetworkSettings)
        }

        /// Published bindings only; Docker inspect uses `null` for exposed-but-unpublished ports.
        public var publishedBindings: [EnginePortBinding] {
            var result: [EnginePortBinding] = []
            for (key, bindings) in NetworkSettings.Ports ?? [:] {
                for host in bindings ?? [] {
                    if let binding = host.binding(inspectKey: key) {
                        result.append(binding)
                    }
                }
            }
            return result
        }
    }

    public static func lines(
        from inspect: Inspect,
        privatePort: String?,
        container: String
    ) throws -> [String] {
        try EnginePortBinding.dockerPortLines(
            inspect.publishedBindings,
            privatePort: privatePort,
            container: container
        )
    }
}
