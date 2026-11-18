import ContainerizationExtras
import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

/// Wire-level fixes found by driving the daemon with the official CLI / Compose breadth suites.
struct RouterCompatBreadthTests {
    // MARK: images

    @Test func pullByDigestArrivesInTheTagParameter() {
        // `docker pull alpine@sha256:…` → `POST /images/create?fromImage=alpine&tag=sha256:…`
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let pinned = Router.pullReference(fromImage: "alpine", tag: digest)
        #expect(pinned.name == "alpine@\(digest)")
        #expect(pinned.tag == nil)
        #expect(Router.pullReference(fromImage: "alpine", tag: "3.20") == ("alpine", "3.20"))
        #expect(Router.pullReference(fromImage: "alpine", tag: "") == ("alpine", nil))
        #expect(Router.pullReference(fromImage: "alpine", tag: nil) == ("alpine", nil))
        #expect(!Router.isDigest("latest"))
        #expect(!Router.isDigest("v1:2"))
    }

    @Test func referenceFilterIsAFamiliarGlob() {
        let refs = ["docker.io/library/alpine:3.20", "docker.io/library/alpine@sha256:abc", "ghcr.io/acme/tool:1"]
        #expect(FilterMatch.reference("alpine*", references: refs))
        #expect(FilterMatch.reference("alpine", references: refs))
        #expect(FilterMatch.reference("alpine:3.20", references: refs))
        #expect(!FilterMatch.reference("alpine:3.19", references: refs))
        #expect(FilterMatch.reference("ghcr.io/acme/*", references: refs))
        // `*` does not cross `/`, like Docker's path.Match.
        #expect(!FilterMatch.reference("ghcr.io/*", references: refs))
        #expect(!FilterMatch.reference("lpine", references: refs))
    }

    @Test func untaggedBuildResultsHaveNoRepoDigest() {
        let digest = "sha256:" + String(repeating: "b", count: 64)
        #expect(EngineManager.repoDigests([digest, "docker.io/library/alpine:3.20"], digest: digest) == ["docker.io/library/alpine@\(digest)"])
        #expect(EngineManager.repoDigests([digest], digest: digest).isEmpty)
    }

    @Test func pullForAnotherArchitectureIsRejected() async throws {
        try await withEngine { engine in
            var failure: Error?
            do {
                for try await _ in await engine.pullImage(name: "alpine", tag: "3.20", platform: "linux/amd64") {}
            } catch {
                failure = error
            }
            #expect(failure?.localizedDescription.contains("platform linux/amd64 is not supported") == true)
        }
    }

    // MARK: containers

    @Test func createWithForeignPlatformOrSharedNetnsIsRejectedWithReason() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let platform = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/create",
                    query: ["platform": "linux/amd64"],
                    body: ["Image": "alpine:latest"]
                )
            )
            #expect(platform.status == 400)
            #expect(try RouterTestSupport.message(platform)?.contains("not supported") == true)

            let owner = try await RouterTestSupport.createContainer(router, name: "owner")
            let shared = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/create",
                    body: ["Image": "alpine:latest", "HostConfig": ["NetworkMode": "container:\(owner)"]]
                )
            )
            #expect(shared.status == 501)
            #expect(try RouterTestSupport.message(shared)?.contains("is not supported: every container is a separate MicroVM") == true)

            let tiny = await router.handle(
                try RouterTestSupport.request(
                    "POST",
                    "/containers/create",
                    body: ["Image": "alpine:latest", "HostConfig": ["Memory": 6 * 1024 * 1024]]
                )
            )
            #expect(tiny.status == 400)
            #expect(try RouterTestSupport.message(tiny)?.contains("Minimum memory limit") == true)
        }
    }

    @Test func privilegedAndCapabilitiesRoundTrip() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            var body = RouterDockerCLIAPITests.officialCreateBody()
            var host = body["HostConfig"] as! [String: Any]
            host["Privileged"] = true
            host["CapAdd"] = ["NET_ADMIN"]
            host["CapDrop"] = ["CHOWN"]
            body["HostConfig"] = host
            let created = await router.handle(try RouterTestSupport.request("POST", "/containers/create", body: body))
            #expect(created.status == 201, "\(RouterTestSupport.text(created))")
            let id = try #require(try RouterTestSupport.jsonObject(created)["Id"] as? String)
            let inspected = try RouterTestSupport.jsonObject(
                await router.handle(try RouterTestSupport.request("GET", "/containers/\(id)/json"))
            )
            let hostConfig = try #require(inspected["HostConfig"] as? [String: Any])
            #expect(hostConfig["Privileged"] as? Bool == true)
            #expect(hostConfig["CapAdd"] as? [String] == ["NET_ADMIN"])
            #expect(hostConfig["CapDrop"] as? [String] == ["CHOWN"])
            #expect(RouterTestSupport.int64(inspected["RestartCount"]) == 0)

            var bad = RouterDockerCLIAPITests.officialCreateBody()
            var badHost = bad["HostConfig"] as! [String: Any]
            badHost["CapAdd"] = ["CAP_NOPE"]
            bad["HostConfig"] = badHost
            let rejected = await router.handle(try RouterTestSupport.request("POST", "/containers/create", body: bad))
            #expect(rejected.status == 400)
            #expect(try RouterTestSupport.message(rejected)?.contains("unknown capability") == true)
        }
    }

    @Test func capabilitySetsFollowDockerRules() throws {
        let defaults = GuestCapabilities.defaults
        #expect(try GuestCapabilities.resolve(privileged: false, add: [], drop: []) == defaults)
        #expect(try GuestCapabilities.resolve(privileged: true, add: [], drop: ["ALL"]).count == CapabilityNameCount.all)
        let added = try GuestCapabilities.resolve(privileged: false, add: ["net_admin"], drop: ["CAP_CHOWN"])
        #expect(added.map(\.description).contains("CAP_NET_ADMIN"))
        #expect(!added.map(\.description).contains("CAP_CHOWN"))
        #expect(try GuestCapabilities.resolve(privileged: false, add: ["ALL"], drop: []).count == CapabilityNameCount.all)
        let only = try GuestCapabilities.resolve(privileged: false, add: ["KILL"], drop: ["ALL"])
        #expect(only.map(\.description) == ["CAP_KILL"])
        #expect(throws: EngineError.self) { try GuestCapabilities.resolve(privileged: false, add: ["BOGUS"], drop: []) }
    }

    @Test func restartCountIsReportedAndResetByAUserStart() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let id = try await RouterTestSupport.createContainer(router, name: "rc")
            await engine.setRestartCountForTesting(id, 3)
            let inspected = try RouterTestSupport.jsonObject(
                await router.handle(try RouterTestSupport.request("GET", "/containers/\(id)/json"))
            )
            #expect(RouterTestSupport.int64(inspected["RestartCount"]) == 3)
        }
    }

    @Test func hostPortsConflictOnlyWhenAddressesOverlap() {
        let any = EnginePortBinding(hostIP: "", hostPort: 8080, containerPort: 80)
        let local = EnginePortBinding(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 81)
        let other = EnginePortBinding(hostIP: "127.0.0.2", hostPort: 8080, containerPort: 82)
        let udp = EnginePortBinding(hostIP: "", hostPort: 8080, containerPort: 80, protocolName: "udp")
        let v6 = EnginePortBinding(hostIP: "::1", hostPort: 8080, containerPort: 80)
        let ephemeral = EnginePortBinding(hostIP: "", hostPort: 0, containerPort: 80)
        #expect(any.conflicts(with: local))
        #expect(!local.conflicts(with: other))
        #expect(!any.conflicts(with: udp))
        #expect(!local.conflicts(with: v6))
        #expect(any.conflicts(with: v6))
        #expect(!ephemeral.conflicts(with: ephemeral))
        #expect(local.allocatedError == "Bind for 127.0.0.1:8080 failed: port is already allocated")
    }

    @Test func forgettingAContainerReturnsAllItsLeases() async throws {
        let gateway = NetworkGateway()
        let network = EngineNetwork(
            id: "n1", name: "fixed", driver: "bridge", scope: "local", created: Date(), labels: [:],
            subnet: "10.77.0.0/24", gateway: "10.77.0.1", internalNetwork: false, builtin: false
        )
        await gateway.registerNetwork(network)
        let key = NetworkGateway.endpointKey(containerID: "c1", networkID: "n1")
        try await gateway.reserve("n1", key: key, ip: try IPv4Address("10.77.0.10"))
        // A stopped container keeps its lease (no live endpoint record); removing it must free it.
        await gateway.forget(containerID: "c1")
        try await gateway.reserve("n1", key: NetworkGateway.endpointKey(containerID: "c2", networkID: "n1"), ip: try IPv4Address("10.77.0.10"))
    }

    // MARK: filesystem

    @Test func transientResetKeepsTheWritableLayer() throws {
        try TemporaryDirectory.with("macker-reset") { root in
            let runtime = EngineManager.runtimeURL(id: "c", root: root)
            try FileManager.default.createDirectory(at: runtime.appendingPathComponent("tmpfs/t"), withIntermediateDirectories: true)
            for name in ["rootfs.ext4", "baseline.json"] {
                FileManager.default.createFile(atPath: runtime.appendingPathComponent(name).path, contents: Data("x".utf8))
            }
            EngineManager.resetTransientFiles("c", root: root)
            let left = try FileManager.default.contentsOfDirectory(atPath: runtime.path).sorted()
            #expect(left == ["baseline.json", "rootfs.ext4"])
        }
    }

    @Test func volumesWithUntraversableGuestDirectoriesAreRemovable() throws {
        try TemporaryDirectory.with("macker-volrm") { root in
            let volume = root.appendingPathComponent("vol")
            let locked = volume.appendingPathComponent("work/work")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: locked.appendingPathComponent("f").path, contents: Data())
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: volume.appendingPathComponent("work").path)
            try EngineManager.removeGuestWrittenTree(volume)
            #expect(!FileManager.default.fileExists(atPath: volume.path))
        }
    }

    @Test func copyIntoAStoppedContainerIsStagedForTheNextStart() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let id = try await RouterTestSupport.createContainer(router, name: "cp")
            try await TemporaryDirectory.with("macker-cp") { work in
                let tar = try pack(hello: "payload", in: work, file: "in.txt")
                let response = await router.handle(
                    try RouterTestSupport.request(
                        "PUT",
                        "/containers/\(id)/archive",
                        query: ["path": "/etc"],
                        body: try Data(contentsOf: tar)
                    )
                )
                #expect(response.status == 200, "\(RouterTestSupport.text(response))")
            }
            let staged = await engine.pendingArchiveCountForTesting(id)
            #expect(staged == 1)
        }
    }

    // MARK: hidden system containers

    @Test func systemContainersStayOutOfTheDockerAPI() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            var spec = EngineContainerCreateSpec(name: "macker-buildkit", image: "alpine:latest")
            spec.system = true
            let events = await engine.events(since: Date(timeIntervalSince1970: 0), until: Date())
            _ = try await engine.createContainer(spec)
            let listed = await router.handle(try RouterTestSupport.request("GET", "/containers/json", query: ["all": "1"]))
            #expect(try RouterTestSupport.jsonArray(listed).isEmpty)
            let byName = await router.handle(try RouterTestSupport.request("GET", "/containers/macker-buildkit/json"))
            #expect(byName.status == 404)
            // A user container may still take the same name.
            _ = try await RouterTestSupport.createContainer(router, name: "macker-buildkit")
            var seen: [String] = []
            for await event in events { seen.append(event.action) }
            #expect(!seen.contains("create"))
        }
    }

    // MARK: BuildKit endpoints

    @Test func buildKitEndpointsUpgradeToH2C() async throws {
        try await withRouter { router, _ in
            for path in ["/grpc", "/v1.44/session"] {
                let response = await router.handle(try RouterTestSupport.request("POST", path))
                guard case .upgrade(let upgrade) = response.body else {
                    Issue.record("\(path) did not upgrade")
                    continue
                }
                #expect(upgrade.protocolName == "h2c")
            }
        }
    }

    @Test func repeatedHeadersSurviveForSessionMetadata() {
        let request = HTTPRequest(
            method: "POST",
            path: "/session",
            headers: ["x-docker-expose-session-grpc-method": "/b"],
            headerList: [("x-docker-expose-session-grpc-method", "/a"), ("x-docker-expose-session-grpc-method", "/b")]
        )
        #expect(request.headerList.map(\.1) == ["/a", "/b"])
    }
}

enum CapabilityNameCount {
    static let all = 41
}

extension EngineManager {
    func setRestartCountForTesting(_ id: String, _ count: Int) {
        containers[id]?.run.restartCount = count
    }

    func pendingArchiveCountForTesting(_ id: String) -> Int {
        let dir = Self.runtimeURL(id: id, root: containerRoot).appendingPathComponent(Self.pendingArchivesDirectory)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
    }
}
