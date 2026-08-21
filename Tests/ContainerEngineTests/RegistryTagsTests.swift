import Foundation
import Testing
@testable import ContainerEngine

struct RegistryTagsTests {
    @Test func parsesBearerChallenge() {
        let challenge = #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/alpine:pull""#
        let params = RegistryTags.parseAuthParams(String(challenge.dropFirst("Bearer ".count)))
        #expect(params["realm"] == "https://auth.docker.io/token")
        #expect(params["service"] == "registry.docker.io")
        #expect(params["scope"] == "repository:library/alpine:pull")
    }

    @Test func ignoresNonBearerChallenge() async throws {
        let token = try await RegistryTags.fetchBearer(
            challenge: #"Basic realm="registry""#,
            basic: nil,
            fallbackScope: "repository:library/alpine:pull"
        )
        #expect(token == nil)
    }

    @Test func extractsPaginationCursor() {
        #expect(
            RegistryTags.nextCursor(link: #"</v2/library/alpine/tags/list?last=3.19&n=100>; rel="next""#) == "3.19"
        )
        #expect(RegistryTags.nextCursor(link: #"</v2/library/alpine/tags/list?last=3.20>; rel=next"#) == "3.20")
    }

    @Test func noLinkHeaderMeansLastPage() {
        #expect(RegistryTags.nextCursor(link: nil) == nil)
        #expect(RegistryTags.nextCursor(link: #"</v2/library/alpine/tags/list?last=3.19>; rel="prev""#) == nil)
        #expect(RegistryTags.nextCursor(link: "garbage") == nil)
    }

    @Test func registryEndpointSplitsHostPortAndMapsDockerHub() {
        let hub = RegistryTags.registryEndpoint("docker.io")
        #expect(hub.host == "registry-1.docker.io")
        #expect(hub.port == nil)
        let local = RegistryTags.registryEndpoint("localhost:5000")
        #expect(local.host == "localhost")
        #expect(local.port == 5000)
        let ipv6 = RegistryTags.splitHostPort("[::1]:5000")
        #expect(ipv6.host == "::1")
        #expect(ipv6.port == 5000)
    }
}
