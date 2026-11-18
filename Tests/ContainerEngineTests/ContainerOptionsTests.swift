import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct ContainerOptionsTests {
    @Test func formatLogsHonorsTailSinceUntil() {
        let older = "2020-01-01T00:00:00.000000000Z hello"
        let newer = "2020-01-01T00:00:10.000000000Z world"
        let text = "\(older)\n\(newer)\n"
        let since = Date(timeIntervalSince1970: 1_577_836_805)
        let until = Date(timeIntervalSince1970: 1_577_836_820)

        #expect(Router.formatLogs(text, timestamps: false, tail: "1") == "\(newer)\n")
        #expect(Router.formatLogs(text, timestamps: false, tail: "all").contains("hello"))
        #expect(Router.formatLogs(text, timestamps: false, tail: nil, since: since) == "\(newer)\n")
        #expect(Router.formatLogs(text, timestamps: false, tail: nil, until: since) == "\(older)\n")
        #expect(
            Router.formatLogs(text, timestamps: false, tail: nil, since: since, until: until) == "\(newer)\n"
        )
        let stamped = Router.formatLogs("plain\n", timestamps: true, tail: nil)
        #expect(stamped.hasSuffix(" plain\n"))
        #expect(Router.logTimestamp(stamped.trimmingCharacters(in: .newlines)) != nil)
    }

    @Test func listFiltersByNameStatusLabelAndUntil() async throws {
        try await withSeededEngine(
            [
                stubContainer(
                    id: String(repeating: "a", count: 64),
                    name: "web",
                    image: "nginx:latest",
                    labels: ["env": "prod"],
                    state: "exited",
                    created: Date(timeIntervalSince1970: 1_000),
                    mounts: [
                        EngineMount(type: "volume", name: "data", source: "/vols/data", destination: "/var/lib", rw: true)
                    ]
                ),
                stubContainer(
                    id: String(repeating: "b", count: 64),
                    name: "worker",
                    image: "alpine:latest",
                    labels: ["env": "test"],
                    state: "created",
                    created: Date(timeIntervalSince1970: 2_000)
                ),
            ]
        ) { engine in
            let named = try await engine.listContainers(all: true, filters: ["name": ["web"]])
            #expect(named.map(\.id) == [String(repeating: "a", count: 64)])

            let created = try await engine.listContainers(all: true, filters: ["status": ["created"]])
            #expect(created.map(\.id) == [String(repeating: "b", count: 64)])

            let labeled = try await engine.listContainers(all: true, filters: ["label": ["env=test"]])
            #expect(labeled.map(\.id) == [String(repeating: "b", count: 64)])

            let volumes = try await engine.listContainers(all: true, filters: ["volume": ["data"]])
            #expect(volumes.map(\.id) == [String(repeating: "a", count: 64)])

            let until = try await engine.listContainers(all: true, filters: ["until": ["1500"]])
            #expect(until.map(\.id) == [String(repeating: "a", count: 64)])

            let before = try await engine.listContainers(
                all: true,
                filters: ["before": [String(repeating: "b", count: 64)]]
            )
            #expect(before.map(\.id) == [String(repeating: "a", count: 64)])
        }
    }

    @Test func inspectSizeUsesRootfsFile() async throws {
        let id = String(repeating: "c", count: 64)
        try await TemporaryDirectory.with("macker-container-size") { dir in
            try persist(stubContainer(id: id, name: "sized", state: "exited"), in: dir)
            let rootfs = dir.appendingPathComponent("containers/\(id)/rootfs.ext4")
            try FileManager.default.createDirectory(at: rootfs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: rootfs)

            let engine = try EngineManager(storePath: dir)
            let hidden = try await engine.inspectContainer(id)
            #expect(hidden.sizeRw == -1)
            let sized = try await engine.inspectContainer(id, size: true)
            #expect(sized.sizeRw == 4096)
            #expect(sized.sizeRootFs == 4096)

            let listed = try await engine.listContainers(all: true, size: true)
            #expect(listed.first?.sizeRw == 4096)
        }
    }

    @Test func pruneHonorsLabelFilterAndReclaimsDisk() async throws {
        let drop = String(repeating: "d", count: 64)
        let keep = String(repeating: "e", count: 64)
        try await TemporaryDirectory.with("macker-container-prune") { dir in
            try persist(
                stubContainer(id: drop, name: "drop", labels: ["env": "test"], state: "exited"),
                in: dir
            )
            try persist(
                stubContainer(id: keep, name: "keep", labels: ["env": "prod"], state: "exited"),
                in: dir
            )
            let rootfs = dir.appendingPathComponent("containers/\(drop)/rootfs.ext4")
            try FileManager.default.createDirectory(at: rootfs.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 2, count: 2048).write(to: rootfs)

            let engine = try EngineManager(storePath: dir)
            let pruned = try await engine.pruneContainers(filters: ["label": ["env=test"]])
            #expect(pruned.deleted == [drop])
            #expect(pruned.spaceReclaimed == 2048)
            let remaining = try await engine.listContainers(all: true)
            #expect(remaining.map(\.id) == [keep])
        }
    }

    @Test func unknownSinceFilterThrows() async throws {
        try await withSeededEngine([stubContainer(id: String(repeating: "f", count: 64), name: "only")]) { engine in
            do {
                _ = try await engine.listContainers(all: true, filters: ["since": ["missing"]])
                Issue.record("expected containerNotFound")
            } catch EngineError.containerNotFound {
            }
        }
    }

    @Test func restartPolicyParsesAndDecides() throws {
        #expect(try EngineRestartPolicy.parse("no") == .none)
        #expect(try EngineRestartPolicy.parse("always").name == "always")
        let limited = try EngineRestartPolicy.parse("on-failure:2")
        #expect(limited.maximumRetryCount == 2)
        #expect(limited.shouldRestart(exitCode: 1, action: "die", restartCount: 0))
        #expect(!limited.shouldRestart(exitCode: 1, action: "die", restartCount: 2))
        #expect(!limited.shouldRestart(exitCode: 0, action: "die", restartCount: 0))
        let always = try EngineRestartPolicy.parse("always")
        #expect(!always.shouldRestart(exitCode: 0, action: "stop", restartCount: 0))
        #expect(!always.shouldRestart(exitCode: 137, action: "kill", restartCount: 0))
        #expect(always.shouldRestart(exitCode: 0, action: "die", restartCount: 0))
        #expect(!always.shouldRestart(exitCode: 0, action: "shutdown", restartCount: 0))
        let unlessStopped = try EngineRestartPolicy.parse("unless-stopped")
        #expect(!unlessStopped.shouldRestart(exitCode: 0, action: "stop", restartCount: 0))
        #expect(unlessStopped.shouldRestart(exitCode: 1, action: "die", restartCount: 0))
        let onFailure = try EngineRestartPolicy.parse("on-failure")
        #expect(!onFailure.shouldRestart(exitCode: 137, action: "stop", restartCount: 0))
        #expect(!onFailure.shouldRestart(exitCode: 137, action: "kill", restartCount: 0))
        #expect(onFailure.shouldRestart(exitCode: 1, action: "die", restartCount: 0))
        #expect(always.shouldStartAfterDaemonRestart(wasActive: false, hasStarted: true))
        #expect(!always.shouldStartAfterDaemonRestart(wasActive: false, hasStarted: false))
        #expect(unlessStopped.shouldStartAfterDaemonRestart(wasActive: true, hasStarted: true))
        #expect(!unlessStopped.shouldStartAfterDaemonRestart(wasActive: false, hasStarted: true))
        #expect(!onFailure.shouldStartAfterDaemonRestart(wasActive: true, hasStarted: true))
        #expect(always.resumesAfterDaemonExit)
        #expect(unlessStopped.resumesAfterDaemonExit)
        #expect(!onFailure.resumesAfterDaemonExit)
        #expect(throws: EngineError.self) {
            _ = try EngineRestartPolicy.parse("maybe")
        }
    }

    @Test func restoreSelectsAlwaysAndUnlessStopped() throws {
        try TemporaryDirectory.with("macker-restart-restore") { dir in
            let alwaysRun = stubRestartContainer(id: String(repeating: "1", count: 64), name: "always-run", policy: "always", state: "running", startedAt: Date())
            let alwaysStopped = stubRestartContainer(id: String(repeating: "2", count: 64), name: "always-stop", policy: "always", state: "exited", startedAt: Date())
            let alwaysCreated = stubRestartContainer(id: String(repeating: "3", count: 64), name: "always-new", policy: "always", state: "created", startedAt: nil)
            let unlessRun = stubRestartContainer(id: String(repeating: "4", count: 64), name: "unless-run", policy: "unless-stopped", state: "running", startedAt: Date())
            let unlessStopped = stubRestartContainer(id: String(repeating: "5", count: 64), name: "unless-stop", policy: "unless-stopped", state: "exited", startedAt: Date())
            let onFailure = stubRestartContainer(id: String(repeating: "6", count: 64), name: "fail", policy: "on-failure", state: "running", startedAt: Date())
            var containers = Dictionary(
                uniqueKeysWithValues: [alwaysRun, alwaysStopped, alwaysCreated, unlessRun, unlessStopped, onFailure].map { ($0.id, $0) }
            )
            let runtime = EngineManager.runtimeURL(id: alwaysRun.id, root: dir)
            let tmpfs = runtime.appendingPathComponent("tmpfs")
            let disk = runtime.appendingPathComponent("rootfs.ext4")
            let baseline = runtime.appendingPathComponent("baseline.json")
            let marker = Data("preserved".utf8)
            try FileManager.default.createDirectory(at: tmpfs, withIntermediateDirectories: true)
            try marker.write(to: disk)
            try marker.write(to: baseline)

            let restart = EngineManager.restoreContainers(&containers, root: dir)
            #expect(try Data(contentsOf: disk) == marker)
            #expect(try Data(contentsOf: baseline) == marker)
            #expect(!FileManager.default.fileExists(atPath: tmpfs.path))
            #expect(Set(restart) == Set([alwaysRun.id, alwaysStopped.id, unlessRun.id]))
            #expect(containers[alwaysRun.id]?.state == "exited")
            #expect(containers[unlessRun.id]?.exitCode == 255)
            #expect(containers[alwaysStopped.id]?.state == "exited")
            #expect(containers[alwaysCreated.id]?.state == "created")
        }
    }

    @Test func networkAttachSpecParsesAdvancedSyntax() throws {
        let spec = try EngineNetworkAttachSpec.parse("name=front,ip=172.20.0.10,alias=web,alias=api,mac=aa:bb:cc:dd:ee:ff")
        #expect(spec.name == "front")
        #expect(spec.ipv4 == "172.20.0.10")
        #expect(spec.aliases == ["web", "api"])
        #expect(spec.macAddress == "aa:bb:cc:dd:ee:ff")
        let request = try spec.asRequest()
        #expect(request.ipv4 == "172.20.0.10")
        #expect(request.macAddress == "aa:bb:cc:dd:ee:ff")
        let v6Spec = try EngineNetworkAttachSpec.parse("name=front,ip6=fd00::1").asRequest()
        #expect(v6Spec.ipv6 == "fd00::1")
        #expect(throws: EngineError.self) {
            _ = try EngineNetworkAttachSpec.parse("name=front,ip6=not-an-ip").asRequest()
        }
    }

    @Test func volumeSpecParsesMountTmpfsAndVolumesFrom() throws {
        let bind = try EngineVolumeSpec.parseMount("type=bind,source=/tmp/data,target=/data,readonly")
        #expect(bind.type == "bind")
        #expect(bind.source == "/tmp/data")
        #expect(bind.destination == "/data")
        #expect(bind.readOnly)
        let tmpfs = try EngineVolumeSpec.parseTmpfs("/run:rw,noexec")
        #expect(tmpfs.type == "tmpfs")
        #expect(tmpfs.destination == "/run")
        let from = EngineVolumeSpec.parseVolumesFrom("web:ro")
        #expect(from.name == "web")
        #expect(from.readOnly == true)
    }

    @Test func extraHostAndLabelFileParse() throws {
        let extra = try EngineExtraHost.parse("db.local:10.1.2.3")
        #expect(extra.host == "db.local")
        #expect(extra.ip == "10.1.2.3")
        let gateway = try EngineExtraHost.parse("host.docker.internal:host-gateway")
        #expect(gateway.ip == "host-gateway")
        let resolved = try EngineExtraHost.parse(
            "host.docker.internal:host-gateway",
            hostGateway: "172.17.0.1"
        )
        #expect(resolved.ip == "172.17.0.1")
        let labels = EngineLabelFile.parse("# comment\nenv=prod\nempty=\nflag\n")
        #expect(labels["env"] == "prod")
        #expect(labels["empty"] == "")
        #expect(labels["flag"] == "")
    }

    @Test func volumeRequestsIncludeTmpfsAndMounts() throws {
        let json = """
        {"Image":"alpine","HostConfig":{"Tmpfs":{"/run":"rw"},"Mounts":[{"Type":"tmpfs","Target":"/tmp"},{"Type":"bind","Source":"/host","Target":"/c","ReadOnly":true}]}}
        """
        let body = try JSONDecoder().decode(DockerCreateContainerRequest.self, from: Data(json.utf8))
        let requests = Router.volumeRequests(from: body)
        #expect(requests.contains { $0.type == "tmpfs" && $0.destination == "/run" })
        #expect(requests.contains { $0.type == "tmpfs" && $0.destination == "/tmp" })
        #expect(requests.contains { $0.type == "bind" && $0.source == "/host" && $0.readOnly })
    }

    @Test func publishAllAddsMissingExposedPorts() {
        let exposed = [
            EnginePortBinding(hostIP: "", hostPort: 80, containerPort: 80, protocolName: "tcp"),
            EnginePortBinding(hostIP: "", hostPort: 443, containerPort: 443, protocolName: "tcp"),
        ]
        var published = [
            EnginePortBinding(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, protocolName: "tcp")
        ]
        for port in exposed where !published.contains(where: { $0.dockerKey == port.dockerKey }) {
            published.append(
                EnginePortBinding(hostIP: "", hostPort: 0, containerPort: port.containerPort, protocolName: port.protocolName)
            )
        }
        #expect(published.contains { $0.containerPort == 80 && $0.hostPort == 8080 })
        #expect(published.contains { $0.containerPort == 443 && $0.hostPort == 0 })
    }
}

private func withSeededEngine(
    _ containers: [EngineContainer],
    _ body: (EngineManager) async throws -> Void
) async throws {
    try await TemporaryDirectory.with("macker-container-opts") { dir in
        for container in containers {
            try persist(container, in: dir)
        }
        try await body(try EngineManager(storePath: dir))
    }
}

private func persist(_ container: EngineContainer, in store: URL) throws {
    let root = store.appendingPathComponent("containers", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(container).write(to: root.appendingPathComponent("\(container.id).json"))
}

private func stubContainer(
    id: String,
    name: String,
    image: String = "alpine:latest",
    labels: [String: String] = [:],
    state: String = "exited",
    created: Date = Date(timeIntervalSince1970: 1),
    mounts: [EngineMount] = []
) -> EngineContainer {
    EngineContainer(
        id: id,
        name: name,
        image: image,
        imageID: "sha256:\(id)",
        command: ["true"],
        env: [],
        workingDir: "/",
        user: "",
        hostname: name,
        labels: labels,
        state: state,
        created: created,
        startedAt: nil,
        finishedAt: created,
        exitCode: 0,
        autoRemove: false,
        memory: 0,
        nanoCpus: 0,
        networkMode: "bridge",
        tty: false,
        openStdin: false,
        mounts: mounts
    )
}

private func stubRestartContainer(
    id: String,
    name: String,
    policy: String,
    state: String,
    startedAt: Date?
) -> EngineContainer {
    var container = stubContainer(id: id, name: name, state: state, created: Date(timeIntervalSince1970: 1))
    container.startedAt = startedAt
    container.finishedAt = state == "exited" ? Date(timeIntervalSince1970: 2) : nil
    container.run.restartPolicy = EngineRestartPolicy(name: policy, maximumRetryCount: 0)
    return container
}
