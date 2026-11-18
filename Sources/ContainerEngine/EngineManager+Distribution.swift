import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation

public struct EngineDistributionInspect: Sendable {
    public var mediaType: String
    public var digest: String
    public var size: Int64
    public var platforms: [Platform]
    public var manifest: Data

    public struct Platform: Sendable {
        public var os: String
        public var architecture: String
        public var variant: String
    }
}

extension EngineManager {
    /// `GET /distribution/{name}/json`. Contacts the registry; does not download layers.
    public func distributionInspect(name: String, registryAuth: String?, insecure: Bool = false) async throws -> EngineDistributionInspect {
        let reference = try Self.normalizedReference(name: name, tag: nil)
        let parsed = try Reference.parse(reference)
        guard let tag = parsed.tag ?? parsed.digest else {
            throw EngineError.invalidReference("invalid image reference \(name)")
        }
        let auth = authStore.authentication(reference: reference, header: registryAuth)
        let client = try RegistryClient(
            reference: reference,
            insecure: insecure,
            auth: auth,
            tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration()
        )
        do {
            let descriptor = try await client.resolve(name: parsed.path, tag: tag)
            let manifest = try await client.fetchData(name: parsed.path, descriptor: descriptor)
            return EngineDistributionInspect(
                mediaType: descriptor.mediaType,
                digest: descriptor.digest,
                size: descriptor.size,
                platforms: Self.platforms(in: manifest),
                manifest: manifest
            )
        } catch {
            throw RegistryErrorMapper.map(error, reference: reference, operation: .pull)
        }
    }

    static func platforms(in manifest: Data) -> [EngineDistributionInspect.Platform] {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
            let manifests = object["manifests"] as? [[String: Any]]
        else {
            return []
        }
        return manifests.compactMap { item in
            guard let platform = item["platform"] as? [String: Any] else { return nil }
            return EngineDistributionInspect.Platform(
                os: platform["os"] as? String ?? "",
                architecture: platform["architecture"] as? String ?? "",
                variant: platform["variant"] as? String ?? ""
            )
        }
    }
}
