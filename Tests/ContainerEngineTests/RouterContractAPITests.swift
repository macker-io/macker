import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct RouterContractAPITests {
    @Test func createWarnsWhenHostConfigIsNotApplied() {
        let body = Data(#"{"Image":"alpine","HostConfig":{"CapAdd":["NET_ADMIN"],"Init":true,"Sysctls":{"net.ipv4.ip_forward":"1"},"ShmSize":67108864,"Memory":0}}"#.utf8)
        let warnings = Router.unsupportedCreateWarnings(body)
        #expect(warnings.contains { $0.contains("ShmSize") })
        #expect(!warnings.contains { $0.contains("CapAdd") })
        #expect(!warnings.contains { $0.contains("Init") })
        #expect(!warnings.contains { $0.contains("Sysctls") })
        #expect(!warnings.contains { $0.contains("Memory") })
    }

    @Test func distributionPathKeepsRepositorySlashes() {
        #expect(Router.distributionName("/distribution/library/alpine:latest/json") == "library/alpine:latest")
        #expect(Router.distributionName("/distribution/docker.io/library/nginx/json") == "docker.io/library/nginx")
        #expect(Router.distributionName("/plugins") == nil)
    }

    @Test func pluginsSwarmAndCheckpointAreNotMissingPages() async throws {
        try await withRouter { router, _ in
            let plugins = await router.handle(try RouterTestSupport.request("GET", "/v1.41/plugins"))
            #expect(plugins.status == 200)
            #expect((try RouterTestSupport.json(plugins) as? [Any])?.isEmpty == true)

            let privileges = await router.handle(try RouterTestSupport.request("GET", "/plugins/privileges"))
            #expect(privileges.status == 400)
            let install = await router.handle(
                try RouterTestSupport.request("GET", "/plugins/privileges", query: ["remote": "vieux/sshfs"])
            )
            #expect(install.status == 501)

            let missingPlugin = await router.handle(try RouterTestSupport.request("GET", "/plugins/vieux%2Fsshfs/json"))
            #expect(missingPlugin.status == 404)
            #expect(try RouterTestSupport.message(missingPlugin)?.contains("vieux/sshfs") == true)

            let nodes = await router.handle(try RouterTestSupport.request("GET", "/nodes"))
            #expect(nodes.status == 503)
            #expect(try RouterTestSupport.message(nodes)?.contains("not a swarm manager") == true)

            let services = await router.handle(try RouterTestSupport.request("GET", "/services/web/logs"))
            #expect(services.status == 503)

            let initSwarm = await router.handle(try RouterTestSupport.request("POST", "/swarm/init"))
            #expect(initSwarm.status == 501)
            #expect(try RouterTestSupport.message(initSwarm)?.contains("not implemented") == true)

            let join = await router.handle(try RouterTestSupport.request("POST", "/swarm/join"))
            #expect(join.status == 501)

            let leave = await router.handle(try RouterTestSupport.request("POST", "/swarm/leave"))
            #expect(leave.status == 503)

            let missingCheckpoint = await router.handle(
                try RouterTestSupport.request("GET", "/containers/missing/checkpoints")
            )
            #expect(missingCheckpoint.status == 404)
        }
    }

    @Test func checkpointOnAKnownContainerIsUnsupported() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let id = try await RouterTestSupport.createContainer(router, name: "ckpt")
            let listed = await router.handle(try RouterTestSupport.request("GET", "/containers/\(id)/checkpoints"))
            #expect(listed.status == 501)
            #expect(try RouterTestSupport.message(listed)?.contains("not supported") == true)
        }
    }

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

            let restarted = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/\(id)/update",
                    body: [
                        "Memory": 0,
                        "CpuShares": 512,
                        "RestartPolicy": ["Name": "on-failure", "MaximumRetryCount": 3],
                    ]
                )
            )
            #expect(restarted.status == 200)
            let warnings = try RouterTestSupport.jsonObject(restarted)["Warnings"] as? [String] ?? []
            #expect(warnings.contains { $0.contains("CpuShares") })
            let afterRestart = await router.handle(try RouterTestSupport.request("GET", "/containers/\(id)/json"))
            let hostAfter = try RouterTestSupport.jsonObject(afterRestart)["HostConfig"] as? [String: Any]
            #expect(RouterTestSupport.int64(hostAfter?["Memory"]) == Int64(67_108_864))
            let policy = hostAfter?["RestartPolicy"] as? [String: Any]
            #expect(policy?["Name"] as? String == "on-failure")
            #expect(RouterTestSupport.int64(policy?["MaximumRetryCount"]) == 3)

            let logs = await router.handle(
                try RouterTestSupport.request("GET", "/containers/\(id)/logs", query: ["stdout": "1", "stderr": "1"])
            )
            #expect(logs.status == 200)
        }
    }

    @Test func invalidPruneFiltersPreserveEligibleResources() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "fixture")
            let container = try await RouterTestSupport.createContainer(router, image: "fixture")
            _ = try await engine.createVolume(.init(name: "keep"))
            let network = await router.handle(try RouterTestSupport.request("POST", "/networks/create", body: ["Name": "keepnet"]))
            try #require(network.status == 201)
            let dangling = try await TemporaryDirectory.with("prune-image") { work in
                try await collectDigest(await engine.importImage(spec: .init(source: "-"), archive: try pack(hello: "untagged", in: work)))
            }
            for (route, invalidValue) in [("/containers/prune", #"{"until":["bad"]}"#),
                                          ("/networks/prune", #"{"label!":[]}"#),
                                          ("/v1.41/volumes/prune", #"{"all":["typo"]}"#),
                                          ("/build/prune", #"{"id":[""]}"#)] {
                for raw in ["bad json", #"{"unknown":["x"]}"#, invalidValue] {
                    let response = await router.handle(try RouterTestSupport.request("POST", route, query: ["all": "1", "filters": raw]))
                    #expect(response.status == 400, "\(route) accepted \(raw)")
                }
            }
            _ = try await engine.inspectContainer(container)
            _ = try await engine.inspectNetwork("keepnet")
            _ = try await engine.inspectVolume("keep")
            _ = try await engine.inspectImage(name: dangling)
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

    @Test func ipv6BridgeNetworkAndStaticEndpoint() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let createdNet = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/networks/create",
                    body: [
                        "Name": "v6net",
                        "EnableIPv6": true,
                        "IPAM": [
                            "Config": [
                                ["Subnet": "172.29.0.0/16", "Gateway": "172.29.0.1"],
                                ["Subnet": "fd00:29::/64", "Gateway": "fd00:29::1"],
                            ]
                        ],
                    ]
                )
            )
            #expect(createdNet.status == 201)

            let inspectedNet = await router.handle(try RouterTestSupport.request("GET", "/networks/v6net"))
            #expect(inspectedNet.status == 200)
            let netObj = try RouterTestSupport.jsonObject(inspectedNet)
            #expect(netObj["EnableIPv6"] as? Bool == true)
            let configs = (netObj["IPAM"] as? [String: Any])?["Config"] as? [[String: Any]] ?? []
            #expect(configs.count == 2)
            #expect(configs[1]["Subnet"] as? String == "fd00:29::/64")
            #expect(configs[1]["Gateway"] as? String == "fd00:29::1")

            let createdContainer = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/create",
                    query: ["name": "v6box"],
                    body: [
                        "Image": "alpine:latest",
                        "HostConfig": ["NetworkMode": "v6net"],
                        "NetworkingConfig": [
                            "EndpointsConfig": [
                                "v6net": [
                                    "IPAMConfig": ["IPv6Address": "fd00:29::42"]
                                ]
                            ]
                        ],
                    ]
                )
            )
            #expect(createdContainer.status == 201)
            let id = try RouterTestSupport.jsonObject(createdContainer)["Id"] as? String ?? ""
            let inspect = await router.handle(try RouterTestSupport.request("GET", "/containers/\(id)/json"))
            let netSettings = try RouterTestSupport.jsonObject(inspect)["NetworkSettings"] as? [String: Any]
            #expect(netSettings?["GlobalIPv6Address"] as? String == "fd00:29::42")
            #expect(netSettings?["IPv6Gateway"] as? String == "fd00:29::1")
            #expect(RouterTestSupport.int64(netSettings?["GlobalIPv6PrefixLen"]) == 64)

            // A later network connect must forward the requested IPv6 too, not just validate it.
            let peer = try await RouterTestSupport.createContainer(router, name: "peer")
            let connected = await router.handle(try RouterTestSupport.request(
                "POST", "/networks/v6net/connect", body: [
                    "Container": peer,
                    "EndpointConfig": ["IPAMConfig": ["IPv6Address": "fd00:29::43"]],
                ]
            ))
            #expect(connected.status == 200)
            let net = try RouterTestSupport.jsonObject(
                await router.handle(try RouterTestSupport.request("GET", "/networks/v6net"))
            )
            let peers = try #require(net["Containers"] as? [String: [String: Any]])
            #expect(peers[peer]?["IPv6Address"] as? String == "fd00:29::43/64")
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
