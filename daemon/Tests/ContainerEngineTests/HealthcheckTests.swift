import Foundation
import Testing
@testable import ContainerEngine

struct HealthcheckTests {
    @Test func parsesShellAndJSONCommands() throws {
        let shell = try EngineHealthcheck.parseDockerfile(
            arguments: "CMD wget -q -O- http://localhost || exit 1",
            flags: DockerfileFlags(["interval": "5s", "retries": "2"])
        )
        #expect(shell.test == ["CMD-SHELL", "wget -q -O- http://localhost || exit 1"])
        #expect(shell.command == ["/bin/sh", "-c", "wget -q -O- http://localhost || exit 1"])
        #expect(shell.interval == 5)
        #expect(shell.retryLimit == 2)

        let exec = try EngineHealthcheck.parseDockerfile(arguments: #"CMD ["curl", "-f", "http://localhost"]"#)
        #expect(exec.test == ["CMD", "curl", "-f", "http://localhost"])
        #expect(exec.command == ["curl", "-f", "http://localhost"])

        let none = try EngineHealthcheck.parseDockerfile(arguments: "NONE")
        #expect(none.isDisabled)
        #expect(none.command == nil)
    }

    @Test func inheritPrefersContainerThenImage() {
        let image = EngineHealthcheck(test: ["CMD-SHELL", "true"])
        #expect(EngineHealthcheck.inherit(nil, image: image)?.test == image.test)
        #expect(EngineHealthcheck.inherit(EngineHealthcheck(test: ["NONE"]), image: image) == nil)
        let override = EngineHealthcheck(test: ["CMD", "false"])
        #expect(EngineHealthcheck.inherit(override, image: image)?.test == override.test)
    }

    @Test func probeStateMachineRespectsStartPeriod() {
        let spec = EngineHealthcheck(test: ["CMD", "true"], startPeriodNanos: 10_000_000_000, retries: 2)
        let started = Date(timeIntervalSince1970: 0)
        var health = EngineHealthState()

        health.apply(exitCode: 1, startedAt: started, spec: spec, now: Date(timeIntervalSince1970: 1))
        #expect(health.status == "starting")
        #expect(health.failingStreak == 0)

        health.apply(exitCode: 0, startedAt: started, spec: spec, now: Date(timeIntervalSince1970: 2))
        #expect(health.status == "healthy")
        #expect(health.failingStreak == 0)

        health.apply(exitCode: 1, startedAt: started, spec: spec, now: Date(timeIntervalSince1970: 20))
        #expect(health.status == "starting")
        #expect(health.failingStreak == 1)

        health.apply(exitCode: 1, startedAt: started, spec: spec, now: Date(timeIntervalSince1970: 21))
        #expect(health.status == "unhealthy")
        #expect(health.failingStreak == 2)
    }

    @Test func dockerStatusAppendsHealth() {
        var container = stubHealthyContainer(state: "running")
        container.startedAt = Date()
        container.health = EngineHealthState(status: "healthy")
        #expect(container.dockerStatus.hasSuffix("(healthy)"))
        container.health = EngineHealthState(status: "starting")
        #expect(container.dockerStatus.hasSuffix("(health: starting)"))
        container.health = EngineHealthState(status: "unhealthy")
        #expect(container.dockerStatus.hasSuffix("(unhealthy)"))
    }

    @Test func listFiltersByHealth() async throws {
        let healthyID = String(repeating: "d", count: 64)
        let noneID = String(repeating: "e", count: 64)
        try await TemporaryDirectory.with("macker-health-filter") { dir in
            var healthy = stubHealthyContainer(id: healthyID, name: "ok", state: "running")
            healthy.health = EngineHealthState(status: "healthy")
            try persist(healthy, in: dir)
            try persist(stubHealthyContainer(id: noneID, name: "plain", state: "running"), in: dir)
            let engine = try EngineManager(storePath: dir)
            let filtered = try await engine.listContainers(all: true, filters: ["health": ["healthy"]])
            #expect(filtered.map(\.id) == [healthyID])
            let none = try await engine.listContainers(all: true, filters: ["health": ["none"]])
            #expect(none.map(\.id) == [noneID])
        }
    }

    @Test func dockerfileAcceptsHealthcheck() throws {
        let file = try Dockerfile.parse(
            """
            FROM alpine
            HEALTHCHECK --interval=5s --timeout=2s CMD wget -q -O- http://127.0.0.1/ || exit 1
            """
        )
        #expect(file.stages[0].instructions.last?.name == "HEALTHCHECK")
        #expect(file.stages[0].instructions.last?.flags["interval"] == "5s")
        #expect(file.stages[0].instructions.last?.arguments.hasPrefix("CMD ") == true)
    }

    @Test func commitInstructionParsesHealthcheck() throws {
        var config = CommitRuntimeConfig()
        try CommitConfig.applyInstruction("HEALTHCHECK --retries=4 CMD echo ok", to: &config)
        #expect(config.Healthcheck?.Test == ["CMD-SHELL", "echo ok"])
        #expect(config.Healthcheck?.Retries == 4)
        try CommitConfig.applyInstruction("HEALTHCHECK NONE", to: &config)
        #expect(config.Healthcheck?.Test == ["NONE"])
    }
}

private func persist(_ container: EngineContainer, in store: URL) throws {
    let root = store.appendingPathComponent("containers", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(container).write(to: root.appendingPathComponent("\(container.id).json"))
}

private func stubHealthyContainer(
    id: String = String(repeating: "f", count: 64),
    name: String = "app",
    state: String = "running"
) -> EngineContainer {
    EngineContainer(
        id: id,
        name: name,
        image: "alpine:latest",
        imageID: "sha256:\(id)",
        command: ["sleep", "inf"],
        env: [],
        workingDir: "/",
        user: "",
        hostname: name,
        labels: [:],
        state: state,
        created: Date(),
        startedAt: Date(),
        finishedAt: nil,
        exitCode: 0,
        autoRemove: false,
        memory: 0,
        nanoCpus: 0,
        networkMode: "bridge",
        tty: false,
        openStdin: false,
        mounts: []
    )
}
