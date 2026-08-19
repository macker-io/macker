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
