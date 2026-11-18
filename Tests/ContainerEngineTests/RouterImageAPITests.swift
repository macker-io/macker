import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct RouterImageAPITests {
    @Test func inspectTagAndUntagImage() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine", hello: "base\n")

            let inspected = await router.handle(try RouterTestSupport.request("GET", "/images/alpine:latest/json"))
            #expect(inspected.status == 200)
            let inspect = try RouterTestSupport.jsonObject(inspected)
            let id = inspect["Id"] as? String
            #expect(id?.hasPrefix("sha256:") == true)
            #expect((inspect["RepoTags"] as? [String])?.contains { $0.hasSuffix("alpine:latest") } == true)

            let missingRepo = await router.handle(try RouterTestSupport.request("POST", "/images/alpine:latest/tag"))
            #expect(missingRepo.status == 400)

            let tagged = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/images/alpine:latest/tag",
                    query: ["repo": "demo", "tag": "v2"]
                )
            )
            #expect(tagged.status == 201)
            let alias = await router.handle(try RouterTestSupport.request("GET", "/images/demo:v2/json"))
            #expect(try RouterTestSupport.jsonObject(alias)["Id"] as? String == id)

            let untagged = await router.handle(try RouterTestSupport.request("DELETE", "/images/demo:v2"))
            #expect(untagged.status == 200)
            let items = try RouterTestSupport.jsonArray(untagged)
            #expect(items.contains { $0["Untagged"] != nil && $0["Deleted"] == nil })
            #expect(!items.contains { $0["Deleted"] != nil })

            let remaining = await router.handle(try RouterTestSupport.request("GET", "/images/alpine:latest/json"))
            #expect(remaining.status == 200)
        }
    }

    @Test func listReportsPlatformAndReferencesFromCreatedContainers() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "in-use")
            try await RouterTestSupport.importTagged(engine, repo: "unused")
            _ = try await RouterTestSupport.createContainer(router, image: "in-use:latest")
            let response = await router.handle(try RouterTestSupport.request("GET", "/images/json", query: ["all": "1"]))
            #expect(response.status == 200)
            let images = try RouterTestSupport.jsonArray(response)
            for (repo, count) in [("in-use", 1), ("unused", 0)] {
                let row = try #require(images.first { image in
                    (image["RepoTags"] as? [String])?.contains { $0.hasSuffix("/\(repo):latest") } == true
                })
                #expect(row["Containers"] as? Int == count)
                #expect((row["Platform"] as? String)?.hasPrefix("linux/") == true)
                #expect((row["Created"] as? Int64 ?? 0) > 0)
            }
        }
    }

    @Test func pruneRemovesDanglingImages() async throws {
        try await withRouter { router, engine in
            try await TemporaryDirectory.with("macker-router-dangling") { work in
                _ = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-"),
                        archive: try pack(hello: "dangling\n", in: work)
                    )
                )
            }
            try await RouterTestSupport.importTagged(engine, repo: "keep", hello: "keep\n")

            let pruned = await router.handle(try RouterTestSupport.request("POST", "/images/prune"))
            #expect(pruned.status == 200)
            let body = try RouterTestSupport.jsonObject(pruned)
            let deleted = body["ImagesDeleted"] as? [[String: Any]] ?? []
            #expect(!deleted.isEmpty)
            #expect((body["SpaceReclaimed"] as? NSNumber)?.int64Value ?? 0 > 0)

            let listed = await router.handle(
                try RouterTestSupport.request("GET", "/images/json", query: ["all": "1"])
            )
            let tags = try RouterTestSupport.jsonArray(listed).flatMap { $0["RepoTags"] as? [String] ?? [] }
            #expect(tags.contains { $0.contains("keep") })
            #expect(!tags.contains { $0.contains("<none>") })
        }
    }
}
