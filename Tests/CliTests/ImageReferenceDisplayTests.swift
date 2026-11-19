import MackerTransport
import Testing

struct ImageReferenceDisplayTests {
    @Test(arguments: [
        ("docker.io/library/alpine", "alpine"),
        ("docker.io/library/alpine:3.24", "alpine:3.24"),
        ("docker.io/library/alpine@sha256:abc", "alpine@sha256:abc"),
        ("docker.io/macker/alpine:3.24", "docker.io/macker/alpine:3.24"),
        ("registry.example:5000/library/alpine", "registry.example:5000/library/alpine"),
        ("alpine:3.24", "alpine:3.24"),
        ("sha256:abc", "sha256:abc"),
    ])
    func shortensOnlyDockerHubOfficialImages(reference: String, expected: String) {
        #expect(ImageReferenceDisplay.shortened(reference) == expected)
    }
}
