import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct RouterAPITests {
    @Test func pingAndVersion() async throws {
        try await withRouter { router, _ in
            let ping = await router.handle(try RouterTestSupport.request("GET", "/_ping"))
            #expect(ping.status == 200)
            #expect(RouterTestSupport.text(ping) == "OK")
            #expect(RouterTestSupport.header(ping, "Api-Version") == DockerAPI.version)

            let head = await router.handle(try RouterTestSupport.request("HEAD", "/_ping"))
            #expect(head.status == 200)
            #expect(RouterTestSupport.data(head).isEmpty)

            let versioned = await router.handle(try RouterTestSupport.request("GET", "/v1.41/_ping"))
            #expect(versioned.status == 200)

            let version = await router.handle(try RouterTestSupport.request("GET", "/version"))
            #expect(version.status == 200)
            let body = try RouterTestSupport.jsonObject(version)
            #expect(body["ApiVersion"] as? String == DockerAPI.version)
            #expect(body["Os"] as? String == "linux")
            #expect(body["Arch"] as? String == "arm64")
            #expect(body["MinAPIVersion"] as? String == DockerAPI.minimumVersion)
        }
    }

    @Test func rejectsUnknownPathAndNewerAPI() async throws {
        try await withRouter { router, _ in
            let missing = await router.handle(try RouterTestSupport.request("GET", "/no-such"))
            #expect(missing.status == 404)
            #expect(try RouterTestSupport.jsonObject(missing)["message"] as? String == "page not found")

            let tooNew = await router.handle(try RouterTestSupport.request("GET", "/v1.50/version"))
            #expect(tooNew.status == 400)
            let message = try RouterTestSupport.jsonObject(tooNew)["message"] as? String
            #expect(message?.contains("too new") == true)
            #expect(message?.contains(DockerAPI.version) == true)

            let tooOld = await router.handle(try RouterTestSupport.request("GET", "/v1.23/version"))
            #expect(tooOld.status == 400)
            let oldMessage = try RouterTestSupport.jsonObject(tooOld)["message"] as? String
            #expect(oldMessage?.contains("too old") == true)
            #expect(oldMessage?.contains(DockerAPI.minimumVersion) == true)

            let older = await router.handle(try RouterTestSupport.request("GET", "/v1.40/_ping"))
            #expect(older.status == 200)
            let minimum = await router.handle(try RouterTestSupport.request("GET", "/v1.24/version"))
            #expect(minimum.status == 200)
            let versionBody = try RouterTestSupport.jsonObject(minimum)
            #expect(versionBody["ApiVersion"] as? String == DockerAPI.version)
            #expect(versionBody["MinAPIVersion"] as? String == DockerAPI.minimumVersion)
        }
    }

    @Test func createInspectAndListContainer() async throws {
        try await withRouter { router, engine in
            try await TemporaryDirectory.with("macker-router-create") { work in
                _ = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "alpine", tag: "latest"),
                        archive: try pack(hello: "hi\n", in: work)
                    )
                )
            }

            let created = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/create",
                    query: ["name": "web"],
                    body: [
                        "Image": "alpine:latest",
                        "Cmd": ["echo", "hi"],
                        "HostConfig": [
                            "Memory": 67_108_864,
                            "NanoCpus": 1_000_000_000,
                            "PortBindings": [
                                "80/tcp": [["HostIp": "", "HostPort": "8080"]]
                            ],
                            "RestartPolicy": ["Name": "always", "MaximumRetryCount": 0],
                        ],
                    ]
                )
            )
            #expect(created.status == 201)
            let id = try RouterTestSupport.jsonObject(created)["Id"] as? String
            #expect(id?.count == 64)
            #expect(RouterTestSupport.header(created, "Location") == nil)
            #expect(RouterTestSupport.header(created, "Content-Type") == "application/json")

            let hidden = await router.handle(try RouterTestSupport.request("GET", "/containers/json"))
            #expect(try RouterTestSupport.jsonArray(hidden).isEmpty)

            let listed = await router.handle(
                try RouterTestSupport.request("GET", "/containers/json", query: ["all": "1"])
            )
            #expect(listed.status == 200)
            let summaries = try RouterTestSupport.jsonArray(listed)
            #expect(summaries.count == 1)
            #expect(summaries[0]["Id"] as? String == id)
            #expect((summaries[0]["Names"] as? [String])?.contains("/web") == true)

            let inspected = await router.handle(try RouterTestSupport.request("GET", "/containers/\(id!)/json"))
            #expect(inspected.status == 200)
            let inspect = try RouterTestSupport.jsonObject(inspected)
            #expect(inspect["Name"] as? String == "/web")
            let host = inspect["HostConfig"] as? [String: Any]
            #expect((host?["Memory"] as? NSNumber)?.int64Value == 67_108_864)
            #expect((host?["NanoCpus"] as? NSNumber)?.int64Value == 1_000_000_000)
            let config = inspect["Config"] as? [String: Any]
            #expect(config?["Image"] as? String == "alpine:latest")
        }
    }

    @Test func createContainerValidatesImageAndDriver() async throws {
        try await withRouter { router, _ in
            let missingImage = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/create",
                    body: ["Image": "no-such:latest"]
                )
            )
            #expect(missingImage.status == 404)

            let emptyImage = await router.handle(
                try RouterTestSupport.request("POST", "/containers/create", body: ["Image": ""])
            )
            #expect(emptyImage.status == 400)
            #expect(try RouterTestSupport.jsonObject(emptyImage)["message"] as? String == "Image is required")

            let driver = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/create",
                    body: [
                        "Image": "alpine",
                        "HostConfig": ["VolumeDriver": "nfs"],
                    ]
                )
            )
            #expect(driver.status == 400)
            #expect(
                try RouterTestSupport.jsonObject(driver)["message"] as? String
                    == "volume driver \"nfs\" is not supported"
            )
        }
    }

    @Test func createAndListVolume() async throws {
        try await withRouter { router, _ in
            let created = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/volumes/create",
                    body: ["Name": "data", "Labels": ["env": "test"]]
                )
            )
            #expect(created.status == 201)
            #expect(try RouterTestSupport.jsonObject(created)["Name"] as? String == "data")

            let listed = await router.handle(try RouterTestSupport.request("GET", "/volumes"))
            #expect(listed.status == 200)
            let volumes = try RouterTestSupport.jsonObject(listed)["Volumes"] as? [[String: Any]]
            #expect(volumes?.contains { $0["Name"] as? String == "data" } == true)
        }
    }

    @Test func listsBuiltinNetworks() async throws {
        try await withRouter { router, _ in
            let listed = await router.handle(try RouterTestSupport.request("GET", "/networks"))
            #expect(listed.status == 200)
            let names = Set(try RouterTestSupport.jsonArray(listed).compactMap { $0["Name"] as? String })
            #expect(names.isSuperset(of: ["bridge", "host", "none"]))
        }
    }

    @Test func listsImportedImages() async throws {
        try await withRouter { router, engine in
            try await TemporaryDirectory.with("macker-router-images") { work in
                _ = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "demo", tag: "v1"),
                        archive: try pack(hello: "img\n", in: work)
                    )
                )
            }
            let listed = await router.handle(
                try RouterTestSupport.request("GET", "/images/json", query: ["all": "1"])
            )
            #expect(listed.status == 200)
            let tags = try RouterTestSupport.jsonArray(listed).flatMap { $0["RepoTags"] as? [String] ?? [] }
            #expect(tags.contains { $0.contains("demo") && $0.hasSuffix(":v1") })
        }
    }
}
