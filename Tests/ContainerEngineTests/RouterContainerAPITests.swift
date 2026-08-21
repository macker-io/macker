import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct RouterContainerAPITests {
    @Test func renameDeleteAndPruneCreatedContainers() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let web = try await RouterTestSupport.createContainer(router, name: "web")
            let worker = try await RouterTestSupport.createContainer(router, name: "worker")

            let missingName = await router.handle(try RouterTestSupport.request("POST", "/containers/\(web)/rename"))
            #expect(missingName.status == 400)

            let renamed = await router.handle(
                try RouterTestSupport.request("POST", "/containers/\(web)/rename", query: ["name": "app"])
            )
            #expect(renamed.status == 204)
            let inspected = await router.handle(try RouterTestSupport.request("GET", "/containers/\(web)/json"))
            #expect(try RouterTestSupport.jsonObject(inspected)["Name"] as? String == "/app")

            let deleted = await router.handle(try RouterTestSupport.request("DELETE", "/containers/\(web)"))
            #expect(deleted.status == 204)
            let gone = await router.handle(try RouterTestSupport.request("GET", "/containers/\(web)/json"))
            #expect(gone.status == 404)

            let pruned = await router.handle(try RouterTestSupport.request("POST", "/containers/prune"))
            #expect(pruned.status == 200)
            let removed = try RouterTestSupport.jsonObject(pruned)["ContainersDeleted"] as? [String]
            #expect(removed == [worker])
            let listed = await router.handle(
                try RouterTestSupport.request("GET", "/containers/json", query: ["all": "1"])
            )
            #expect(try RouterTestSupport.jsonArray(listed).isEmpty)
        }
    }

    @Test func listContainersHonorsNameLabelAndStatusFilters() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            _ = try await RouterTestSupport.createContainer(router, name: "web", labels: ["env": "prod"])
            _ = try await RouterTestSupport.createContainer(router, name: "worker", labels: ["env": "test"])

            let named = await router.handle(
                try RouterTestSupport.request(
                    "GET",
                    "/containers/json",
                    query: ["all": "1", "filters": try RouterTestSupport.filters(["name": ["web"]])]
                )
            )
            #expect(try RouterTestSupport.jsonArray(named).map { $0["Names"] as? [String] } == [["/web"]])

            let labeled = await router.handle(
                try RouterTestSupport.request(
                    "GET",
                    "/containers/json",
                    query: ["all": "1", "filters": try RouterTestSupport.filters(["label": ["env=test"]])]
                )
            )
            #expect(try RouterTestSupport.jsonArray(labeled).map { $0["Names"] as? [String] } == [["/worker"]])

            let created = await router.handle(
                try RouterTestSupport.request(
                    "GET",
                    "/containers/json",
                    query: ["all": "1", "filters": try RouterTestSupport.filters(["status": ["created"]])]
                )
            )
            #expect(try RouterTestSupport.jsonArray(created).count == 2)

            let running = await router.handle(
                try RouterTestSupport.request(
                    "GET",
                    "/containers/json",
                    query: ["all": "1", "filters": try RouterTestSupport.filters(["status": ["running"]])]
                )
            )
            #expect(try RouterTestSupport.jsonArray(running).isEmpty)
        }
    }
}
