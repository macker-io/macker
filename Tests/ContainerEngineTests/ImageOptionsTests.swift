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

    @Test func imageMetadataInheritedUnlessOverridden() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-inherit") { work in
                _ = try await collectDigest(await engine.importImage(
                    spec: .init(source: "-", repo: "defaults", tag: "v1",
                                changes: ["LABEL source=image", "LABEL mode=old", "VOLUME /data", "VOLUME /cache"]),
                    archive: try pack(hello: "a", in: work)
                ))
                let id = try await engine.createContainer(.init(
                    image: "defaults:v1", labels: ["mode": "new"],
                    volumeRequests: [.init(type: "volume", source: "named", destination: "/data")]
                )).id
                let record = try await engine.inspectContainer(id).container
                #expect(record.labels == ["source": "image", "mode": "new"])
                #expect(record.mounts.count == 2)
                #expect(record.mounts.first { $0.destination == "/data" }?.name == "named")
                #expect(record.mounts.first { $0.destination == "/cache" }?.anonymous == true)
                try await engine.deleteContainer(id, force: false, removeAnonymousVolumes: true)
                #expect(await engine.listVolumes().map(\.volume.name) == ["named"])
            }
        }
    }

    @Test func prunePreservesExcludedImagesAndRejectsInvalidFilters() async throws {
        try await withRouter { router, engine in
            try await TemporaryDirectory.with("macker-prune-label") { work in
                for (name, labels) in [("keep", ["group=test", "keep=yes"]), ("drop", ["group=test"]), ("other", ["group=other"])] {
                    _ = try await collectDigest(await engine.importImage(
                        spec: .init(source: "-", repo: name, tag: "v1", changes: labels.map { "LABEL " + $0 }),
                        archive: try pack(hello: name, in: work, file: name)
                    ))
                }
                for invalid in ["invalid json", #"{"dangling":["false"],"typo":["keep"]}"#, #"{"until":["not a date"]}"#] {
                    let response = await router.handle(try RouterTestSupport.request("POST", "/images/prune", query: ["filters": invalid]))
                    #expect(response.status == 400)
                }
                let filters = #"{"dangling":{"false":true},"label":{"group=test":true},"label!":{"keep=yes":true}}"#
                let response = await router.handle(try RouterTestSupport.request("POST", "/images/prune", query: ["filters": filters]))
                #expect(response.status == 200)
                _ = try await engine.inspectImage(name: "keep:v1")
                _ = try await engine.inspectImage(name: "other:v1")
                await #expect(throws: EngineError.self) { _ = try await engine.inspectImage(name: "drop:v1") }
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
                let container = try await engine.createContainer(.init(image: "multi:v1"))
                try await engine.deleteContainer(container.id, force: false, removeAnonymousVolumes: false)
                await #expect(throws: EngineError.self) {
                    _ = try await engine.deleteImage(name: digest)
                }

                let untagged = try await engine.deleteImage(name: "multi:v1")
                #expect(untagged.count == 1)
                #expect(untagged[0].untagged != nil)
                #expect(untagged[0].deleted == nil)

                let remaining = try await engine.inspectImage(name: "multi:v2")
                #expect(remaining.id == digest)
                #expect(!remaining.repoTags.contains { $0.hasSuffix(":v1") })

                let removed = try await engine.deleteImage(name: "multi:v2")
                #expect(removed.contains { $0.deleted == digest })
                #expect(!removed.contains { $0.untagged == digest })
                await #expect(throws: EngineError.self) {
                    _ = try await engine.inspectImage(name: "multi:v2")
                }
                await #expect(throws: EngineError.self) {
                    _ = try await engine.inspectImage(name: digest)
                }
            }
        }
    }

    @Test func containerKeepsOriginalImageAcrossRetagAndImageCleanup() async throws {
        try await withEngine { engine in
            try await RouterTestSupport.importTagged(engine, repo: "pinned", hello: "old")
            let id = try await engine.createContainer(.init(image: "pinned")).id
            let original = try await engine.inspectImage(name: "pinned").id
            try await RouterTestSupport.importTagged(engine, repo: "pinned", hello: "new")
            #expect(try await engine.inspectImage(name: "pinned").id != original)

            _ = try await engine.deleteImage(name: original, force: true)
            _ = try await engine.pruneImages(danglingOnly: false, until: nil)
            let container = try await engine.inspectContainer(id).container
            let resolved = try await engine.resolveContainerImage(container)
            #expect(resolved.digest == original)
            #expect(try await engine.inspectImage(name: original).layers.count == 1)
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

    @Test func digestPrefixHelpersPreferUniquePrefixAndRejectSuffix() throws {
        let first = "sha256:deadbeef" + String(repeating: "0", count: 56)
        let second = "sha256:cafebabe" + String(repeating: "1", count: 56)
        let shared = "sha256:abcd" + String(repeating: "0", count: 60)
        let sibling = "sha256:abce" + String(repeating: "1", count: 60)
        let suffix = String(EngineManager.digestHex(first).suffix(12))

        #expect(try EngineManager.resolveDigestPrefix("deadbeef", in: [first, second, first]) == first)
        #expect(try EngineManager.resolveDigestPrefix(EngineManager.digestHex(first), in: [first]) == first)
        #expect(suffix == String(repeating: "0", count: 12))
        #expect(try EngineManager.resolveDigestPrefix(suffix, in: [first, second]) == nil)
        #expect(throws: EngineError.self) {
            _ = try EngineManager.resolveDigestPrefix("abc", in: [shared, sibling])
        }
        #expect(EngineManager.digestIDPrefix("alpine") == nil)
        #expect(EngineManager.digestIDPrefix("sha256:deadbeef") == "deadbeef")
    }

    @Test func sha256RepositoryTagIsNotTreatedAsDigestID() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-sha256-tag") { work in
                let digest = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "sha256", tag: "stable"),
                        archive: try pack(hello: "named\n", in: work)
                    )
                )
                try await engine.tagImage(name: "sha256:stable", repo: "sha256", tag: "also")
                #expect(try await !engine.resolveImageLookup("sha256:stable").byID)
                let untagged = try await engine.deleteImage(name: "sha256:stable")
                #expect(untagged.count == 1)
                #expect(untagged[0].untagged != nil)
                #expect(untagged[0].deleted == nil)
                #expect(try await engine.inspectImage(name: "sha256:also").id == digest)
            }
        }
    }

    @Test func exactSha256HexRepositoryTagClassifiesByActualDigestMatch() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-sha256-hex-tag") { work in
                let digest = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "sha256", tag: "seed"),
                        archive: try pack(hello: "hex-tag\n", in: work)
                    )
                )
                let fakeHex = "aaaaaaaa" + String(repeating: "b", count: 56)
                #expect(fakeHex.count == 64)
                #expect(EngineManager.digestHex(digest) != fakeHex)
                #expect(EngineManager.isDigestReference("sha256:\(fakeHex)"))

                try await engine.tagImage(name: "sha256:seed", repo: "sha256", tag: fakeHex)
                let named = "sha256:\(fakeHex)"
                let lookup = try await engine.resolveImageLookup(named)
                #expect(lookup.image.digest == digest)
                #expect(!lookup.byID)

                // Full digest and short ID keep byID / multi-tag protection.
                #expect(try await engine.resolveImageLookup(digest).byID)
                let short = String(EngineManager.digestHex(digest).prefix(12))
                #expect(try await engine.resolveImageLookup(short).byID)

                try await engine.tagImage(name: named, repo: "sha256", tag: "keep")
                let untagged = try await engine.deleteImage(name: named)
                #expect(untagged.count == 1)
                #expect(untagged[0].untagged != nil)
                #expect(untagged[0].deleted == nil)
                #expect(try await engine.inspectImage(name: "sha256:keep").id == digest)

                await #expect(throws: EngineError.self) {
                    _ = try await engine.deleteImage(name: short)
                }
            }
        }
    }

    @Test func shortImageIDRoundTripsAndProtectsMultiTagDelete() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-short-id") { work in
                let digest = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "short", tag: "v1"),
                        archive: try pack(hello: "short-id\n", in: work)
                    )
                )
                try await engine.tagImage(name: "short:v1", repo: "short", tag: "v2")
                let short = String(EngineManager.digestHex(digest).prefix(12))
                #expect(try await engine.inspectImage(name: short).id == digest)
                #expect(try await engine.resolveImageLookup(short).byID)

                await #expect(throws: EngineError.self) {
                    _ = try await engine.deleteImage(name: short)
                }
                let removed = try await engine.deleteImage(name: short, force: true)
                #expect(removed.contains { $0.deleted == digest })
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

