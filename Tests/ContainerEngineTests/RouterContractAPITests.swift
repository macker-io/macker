import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct RouterContractAPITests {
    @Test func missingQueryParametersAre400() async throws {
        try await withRouter { router, _ in
            try await expectBadRequest(router, "GET", "/images/search", "term query parameter is required")
            try await expectBadRequest(
                router, "POST", "/images/create", "fromImage or fromSrc query parameter is required"
            )
            try await expectBadRequest(router, "POST", "/commit", "container query parameter is required")
            try await expectBadRequest(router, "GET", "/containers/abc/archive", "path query parameter is required")
            try await expectBadRequest(router, "GET", "/containers/abc/logs", "you must choose at least one stream")
            try await expectBadRequest(router, "POST", "/build", "a build context tar is required")

            let buildkit = await router.handle(
                try RouterTestSupport.request("POST", "/build", query: ["version": "2"])
            )
            #expect(buildkit.status == 400)
            #expect(try RouterTestSupport.message(buildkit)?.contains("classic builder") == true)

            let remote = await router.handle(
                try RouterTestSupport.request("POST", "/build", query: ["remote": "https://example.com"])
            )
            #expect(remote.status == 400)
        }
    }

    @Test func imageHistoryAndContainerUpdate() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine", hello: "hist\n")
            let id = try await RouterTestSupport.createContainer(router, name: "web")

            let history = await router.handle(try RouterTestSupport.request("GET", "/images/alpine:latest/history"))
            #expect(history.status == 200)
            let rows = try RouterTestSupport.jsonArray(history)
            #expect(!rows.isEmpty)
            #expect(rows[0]["Id"] as? String != nil)

            let updated = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/\(id)/update",
                    body: ["Memory": 67_108_864, "NanoCpus": 2_000_000_000]
                )
            )
            #expect(updated.status == 200)
            let inspected = await router.handle(try RouterTestSupport.request("GET", "/containers/\(id)/json"))
            let host = try RouterTestSupport.jsonObject(inspected)["HostConfig"] as? [String: Any]
            #expect(RouterTestSupport.int64(host?["Memory"]) == Int64(67_108_864))
            #expect(RouterTestSupport.int64(host?["NanoCpus"]) == Int64(2_000_000_000))

            let logs = await router.handle(
                try RouterTestSupport.request("GET", "/containers/\(id)/logs", query: ["stdout": "1", "stderr": "1"])
            )
            #expect(logs.status == 200)
        }
    }

    @Test func pruneNetworksAndBuildCache() async throws {
        try await withRouter { router, _ in
            _ = await router.handle(
                try RouterTestSupport.request("POST", "/networks/create", body: ["Name": "scratchnet"])
            )
            let prunedNets = await router.handle(try RouterTestSupport.request("POST", "/networks/prune"))
            #expect(prunedNets.status == 200)
            #expect(
                (try RouterTestSupport.jsonObject(prunedNets)["NetworksDeleted"] as? [String])?.contains("scratchnet")
                    == true
            )

            let prunedBuild = await router.handle(try RouterTestSupport.request("POST", "/build/prune"))
            #expect(prunedBuild.status == 200)
            #expect(try RouterTestSupport.jsonObject(prunedBuild)["CachesDeleted"] as? [String] != nil)
        }
    }
}

private func expectBadRequest(
    _ router: Router,
    _ method: String,
    _ path: String,
    _ message: String,
    query: [String: String] = [:]
) async throws {
    let response = await router.handle(try RouterTestSupport.request(method, path, query: query))
    #expect(response.status == 400)
    #expect(try RouterTestSupport.message(response) == message)
}
