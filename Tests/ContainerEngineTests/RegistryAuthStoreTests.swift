import Foundation
import Testing
@testable import ContainerEngine

struct RegistryAuthStoreTests {
    @Test func canonicalServerMapsDockerHubAliases() {
        #expect(RegistryAuthStore.canonicalServer(nil) == RegistryAuthStore.dockerHubIndex)
        #expect(RegistryAuthStore.canonicalServer("") == RegistryAuthStore.dockerHubIndex)
        #expect(RegistryAuthStore.canonicalServer("docker.io") == RegistryAuthStore.dockerHubIndex)
        #expect(RegistryAuthStore.canonicalServer("https://index.docker.io/v1/") == RegistryAuthStore.dockerHubIndex)
        #expect(RegistryAuthStore.canonicalServer("registry-1.docker.io") == RegistryAuthStore.dockerHubIndex)
        #expect(RegistryAuthStore.canonicalServer("ghcr.io") == "ghcr.io")
        #expect(RegistryAuthStore.canonicalServer("https://ghcr.io/v2/") == "ghcr.io")
        #expect(RegistryAuthStore.canonicalServer("localhost:5000") == "localhost:5000")
    }

    @Test func registryHostSplitsPort() {
        let hub = RegistryAuthStore.registryHost(RegistryAuthStore.dockerHubIndex)
        #expect(hub.host == RegistryAuthStore.dockerHubRegistry)
        #expect(hub.port == nil)

        let local = RegistryAuthStore.registryHost("localhost:5000")
        #expect(local.host == "localhost")
        #expect(local.port == 5000)
    }

    @Test func saveLookupAndDeleteRoundTrip() throws {
        let store = try makeStore()
        try store.save(server: "docker.io", username: "alice", password: "secret:with:colons")

        let hub = store.credentials(forServer: "https://index.docker.io/v1/")
        #expect(hub?.username == "alice")
        #expect(hub?.password == "secret:with:colons")
        #expect(store.credentials(forServer: "registry-1.docker.io")?.username == "alice")

        try store.save(server: "ghcr.io", username: "bob", password: "token")
        #expect(store.credentials(forServer: "https://ghcr.io")?.username == "bob")

        try store.delete(server: "docker.io")
        #expect(store.credentials(forServer: "docker.io") == nil)
        #expect(store.credentials(forServer: "ghcr.io")?.username == "bob")

        try store.delete(server: "ghcr.io")
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func fileIsOwnerReadableOnly() throws {
        let store = try makeStore()
        try store.save(server: "ghcr.io", username: "bob", password: "token")
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }

    @Test func authenticationPrefersHeaderThenStore() throws {
        let store = try makeStore()
        try store.save(server: "ghcr.io", username: "stored", password: "stored-pass")

        #expect(store.authentication(reference: "ghcr.io/org/app:latest", header: nil) != nil)

        let header = Data(#"{"username":"header","password":"header-pass"}"#.utf8).base64EncodedString()
        #expect(store.authentication(reference: "ghcr.io/org/app:latest", header: header) != nil)
        #expect(store.authentication(reference: "docker.io/library/alpine:latest", header: nil) == nil)
    }

    @Test func parseHeaderAcceptsAuthAndIdentityToken() {
        let auth = Data("carol:s3cret".utf8).base64EncodedString()
        let withAuth = Data(#"{"auth":"\#(auth)"}"#.utf8).base64EncodedString()
        let decoded = RegistryAuthStore.parseHeader(withAuth)
        #expect(decoded?.username == "carol")
        #expect(decoded?.password == "s3cret")

        let token = Data(#"{"username":"carol","identitytoken":"pat"}"#.utf8).base64EncodedString()
        let fromToken = RegistryAuthStore.parseHeader(token)
        #expect(fromToken?.username == "carol")
        #expect(fromToken?.password == "pat")
    }

    private func makeStore() throws -> RegistryAuthStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macker-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RegistryAuthStore(directory: directory)
    }
}
