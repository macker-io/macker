import Foundation
import Testing
@testable import ContainerEngine

struct ImageOptionsTests {
    @Test func labelFilterMatchesKeyAndValue() {
        let labels = ["foo": "bar", "env": "test"]
        #expect(FilterMatch.labels(labels, specs: ["foo"]))
        #expect(FilterMatch.labels(labels, specs: ["foo=bar"]))
        #expect(!FilterMatch.labels(labels, specs: ["foo=other"]))
        #expect(!FilterMatch.labels(labels, specs: ["missing"]))
        #expect(FilterMatch.labels(labels, specs: ["foo=bar", "env"]))
        #expect(!FilterMatch.labels(labels, specs: ["foo=bar", "env=prod"]))
    }

    @Test func listImagesFiltersByLabel() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-image-label") { work in
                _ = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(
                            source: "-",
                            repo: "labeled",
                            tag: "v1",
                            changes: ["LABEL foo=bar"]
                        ),
                        archive: try pack(hello: "a\n", in: work)
                    )
                )
                _ = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "plain", tag: "v1"),
                        archive: try pack(hello: "b\n", in: work, file: "b.txt")
                    )
                )

                let matched = try await engine.listImages(all: true, filters: ["label": ["foo=bar"]])
                #expect(matched.contains { $0.repoTags.contains { $0.contains("labeled") } })
                #expect(!matched.contains { $0.repoTags.contains { $0.contains("plain") } })
            }
        }
    }

    @Test func listImagesBeforeUnknownImageThrows() async throws {
        try await withEngine { engine in
            await #expect(throws: EngineError.self) {
                _ = try await engine.listImages(filters: ["before": ["no-such-image"]])
            }
        }
    }

    @Test func deleteImageUntagsWhenSiblingsRemain() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-image-untag") { work in
                let digest = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "multi", tag: "v1"),
                        archive: try pack(hello: "x\n", in: work)
                    )
                )
                try await engine.tagImage(name: "multi:v1", repo: "multi", tag: "v2")

                let untagged = try await engine.deleteImage(name: "multi:v1")
                #expect(untagged.count == 1)
                #expect(untagged[0].untagged != nil)
                #expect(untagged[0].deleted == nil)

                let remaining = try await engine.inspectImage(name: "multi:v2")
                #expect(remaining.id == digest)
                #expect(!remaining.repoTags.contains { $0.hasSuffix(":v1") })

                let removed = try await engine.deleteImage(name: "multi:v2")
                #expect(removed.contains { $0.deleted == digest })
                await #expect(throws: EngineError.self) {
                    _ = try await engine.inspectImage(name: "multi:v2")
                }
            }
        }
    }

    @Test func invalidHistoryPlatformThrows() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-image-platform") { work in
                _ = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "hist", tag: "latest"),
                        archive: try pack(hello: "p\n", in: work)
                    )
                )
                await #expect(throws: EngineError.self) {
                    _ = try await engine.imageHistory(name: "hist:latest", platform: "bogus")
                }
            }
        }
    }

    @Test func sameRepositoryMatchesHubAliases() {
        #expect(EngineManager.sameRepository("alpine", "docker.io/library/alpine"))
        #expect(EngineManager.sameRepository("alpine:3.19", "docker.io/library/alpine:latest"))
        #expect(EngineManager.sameRepository("library/alpine", "docker.io/library/alpine"))
        #expect(EngineManager.sameRepository("myuser/app", "docker.io/myuser/app"))
        #expect(!EngineManager.sameRepository("alpine", "ghcr.io/library/alpine"))
        #expect(EngineManager.canonicalRepository("alpine:3.19") == "docker.io/library/alpine")
    }

    @Test func searchFiltersStarsAndOfficial() throws {
        let items = [
            EngineImageSearchResult(name: "a", description: "", starCount: 2, isOfficial: false, isAutomated: false),
            EngineImageSearchResult(name: "b", description: "", starCount: 10, isOfficial: true, isAutomated: false),
        ]
        let starred = try EngineManager.filterSearchResults(items, filters: ["stars": ["3"]])
        #expect(starred.map(\.name) == ["b"])
        let official = try EngineManager.filterSearchResults(items, filters: ["is-official": ["true"]])
        #expect(official.map(\.name) == ["b"])
        #expect(throws: EngineError.self) {
            try EngineManager.filterSearchResults(items, filters: ["nope": ["1"]])
        }
    }
}

