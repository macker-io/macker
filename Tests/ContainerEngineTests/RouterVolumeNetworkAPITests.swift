import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct RouterVolumeNetworkAPITests {
    @Test func inspectDeleteAndPruneVolumes() async throws {
        try await withRouter { router, _ in
            let named = await router.handle(
                try RouterTestSupport.request("POST", "/volumes/create", body: ["Name": "data"])
            )
            #expect(named.status == 201)

            let inspected = await router.handle(try RouterTestSupport.request("GET", "/volumes/data"))
            #expect(inspected.status == 200)
            #expect(try RouterTestSupport.jsonObject(inspected)["Driver"] as? String == "local")

            let missing = await router.handle(try RouterTestSupport.request("GET", "/volumes/no-such"))
            #expect(missing.status == 404)

            let nfs = await router.handle(
                try RouterTestSupport.request("POST", "/volumes/create", body: ["Name": "nfs", "Driver": "nfs"])
            )
            #expect(nfs.status == 400)

            let defaultPrune = await router.handle(try RouterTestSupport.request("POST", "/volumes/prune"))
            #expect(defaultPrune.status == 200)
            let defaultDeleted = try RouterTestSupport.jsonObject(defaultPrune)["VolumesDeleted"] as? [String] ?? []
            #expect(!defaultDeleted.contains("data"))

            let all = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/volumes/prune",
                    query: ["filters": try RouterTestSupport.filters(["all": ["true"]])]
                )
            )
            #expect(try RouterTestSupport.jsonObject(all)["VolumesDeleted"] as? [String] == ["data"])

            let recreated = await router.handle(
                try RouterTestSupport.request("POST", "/volumes/create", body: ["Name": "scratch"])
            )
            #expect(recreated.status == 201)
            let removed = await router.handle(try RouterTestSupport.request("DELETE", "/volumes/scratch"))
            #expect(removed.status == 204)
        }
    }

    @Test func createInspectAndRejectUnsupportedNetworks() async throws {
        try await withRouter { router, _ in
            let created = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/networks/create",
                    body: [
                        "Name": "front",
                        "Driver": "bridge",
                        "Labels": ["env": "test"],
                        "IPAM": ["Config": [["Subnet": "172.20.0.0/16", "Gateway": "172.20.0.1"]]],
                    ]
                )
            )
            #expect(created.status == 201)
            let id = try RouterTestSupport.jsonObject(created)["Id"] as? String
            #expect(id?.count == 64)

            let inspected = await router.handle(try RouterTestSupport.request("GET", "/networks/front"))
            #expect(inspected.status == 200)
            let inspect = try RouterTestSupport.jsonObject(inspected)
            #expect(inspect["Name"] as? String == "front")
            #expect(inspect["Driver"] as? String == "bridge")
            #expect(inspect["Id"] as? String == id)

            let ipv6 = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/networks/create",
                    body: ["Name": "v6", "EnableIPv6": true]
                )
            )
            #expect(ipv6.status == 201)

            let macvlan = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/networks/create",
                    body: ["Name": "mac", "Driver": "macvlan"]
                )
            )
            #expect(macvlan.status == 400)

            let builtin = await router.handle(try RouterTestSupport.request("DELETE", "/networks/bridge"))
            #expect(builtin.status == 409)

            let deleted = await router.handle(try RouterTestSupport.request("DELETE", "/networks/front"))
            #expect(deleted.status == 204)
            let gone = await router.handle(try RouterTestSupport.request("GET", "/networks/front"))
            #expect(gone.status == 404)
        }
    }

    @Test func connectRequiresContainer() async throws {
        try await withRouter { router, _ in
            let response = await router.handle(
                try RouterTestSupport.request("POST", "/networks/bridge/connect", body: [:])
            )
            #expect(response.status == 400)
            #expect(try RouterTestSupport.jsonObject(response)["message"] as? String == "container is required")
        }
    }
}
