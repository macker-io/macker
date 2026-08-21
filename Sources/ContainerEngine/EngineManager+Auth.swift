import ContainerizationOCI
import ContainerizationExtras
import Foundation

extension EngineManager {
    /// Validates registry credentials, then stores them for later pull / push.
    public func login(_ config: AuthConfig) async throws {
        guard let creds = RegistryAuthStore.credentials(from: config) else {
            throw EngineError.invalidArgument("username and password required")
        }

        let canonical = RegistryAuthStore.canonicalServer(config.serveraddress)
        let endpoint = RegistryAuthStore.registryHost(canonical)
        let client = RegistryClient(
            host: endpoint.host,
            scheme: "https",
            port: endpoint.port,
            authentication: BasicAuthentication(username: creds.username, password: creds.password),
            retryOptions: RetryOptions(
                maxRetries: 3,
                retryInterval: 300_000_000,
                shouldRetry: { $0.status.code >= 500 }
            ),
            tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration()
        )
        do {
            try await client.ping()
        } catch {
            throw RegistryErrorMapper.login(error, host: endpoint.host, port: endpoint.port)
        }
        try authStore.save(server: canonical, username: creds.username, password: creds.password)
    }

    /// Drops stored credentials for `serverAddress` (Docker Hub when nil / empty).
    public func logout(serverAddress: String?) throws {
        try authStore.delete(server: RegistryAuthStore.canonicalServer(serverAddress))
    }
}
