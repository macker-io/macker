import Foundation
import Testing
@testable import CliCore

struct ContextStoreTests {
    @Test func createUseAndResolveSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macker-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            DockerGlobalFlags.reset()
            try? FileManager.default.removeItem(at: root)
        }
        DockerGlobalFlags.reset()
        DockerGlobalFlags.configDirectory = root

        #expect(ContextStore.currentName() == "default")
        try ContextStore.create(
            DockerContext(name: "lab", description: "lab", host: "unix:///tmp/lab.sock", skipTLSVerify: false)
        )
        #expect(try ContextStore.load("lab").host == "unix:///tmp/lab.sock")
        try ContextStore.setCurrent("lab")
        #expect(ContextStore.currentName() == "lab")
        #expect(try ContextStore.currentEndpoint() == "unix:///tmp/lab.sock")
        #expect(try DockerGlobalFlags.socketPath(environment: [:]) == "/tmp/lab.sock")

        let ambient = ["MACKER_HOST": "/tmp/macker-env.sock", "DOCKER_HOST": "unix:///tmp/docker-env.sock"]
        #expect(try DockerGlobalFlags.socketPath(environment: ambient) == "/tmp/macker-env.sock")
        _ = DockerGlobalFlags.install(from: ["macker", "--context", "lab", "ps"])
        #expect(try DockerGlobalFlags.socketPath(environment: ambient) == "/tmp/lab.sock")
        _ = DockerGlobalFlags.install(from: ["macker", "-c", "missing", "ps"])
        #expect(throws: CLIError.self) { try DockerGlobalFlags.socketPath(environment: ambient) }
        _ = DockerGlobalFlags.install(from: ["macker", "--context=default", "ps"])
        #expect(try DockerGlobalFlags.socketPath(environment: ambient) == DockerGlobalFlags.unixSocket(ContextStore.defaultContext().host))

        DockerGlobalFlags.context = nil
        #expect(throws: CLIError.self) { try DockerGlobalFlags.socketPath(environment: ["DOCKER_HOST": "tcp://localhost:2376"]) }
        DockerGlobalFlags.host = "unix:///tmp/override.sock"
        #expect(try DockerGlobalFlags.socketPath(environment: [:]) == "/tmp/override.sock")

        let stripped = DockerGlobalFlags.install(from: ["macker", "--context", "other", "-H", "unix:///tmp/flag.sock", "ps", "-a"])
        #expect(stripped == ["macker", "ps", "-a"])
        #expect(throws: CLIError.self) { try DockerGlobalFlags.socketPath(environment: ambient) }
        #expect(DockerGlobalFlags.context == "other")
        #expect(DockerGlobalFlags.host == "unix:///tmp/flag.sock")

        #expect(DockerGlobalFlags.install(from: ["macker", "ps", "-h"]) == ["macker", "ps", "--help"])
        #expect(DockerGlobalFlags.install(from: ["macker", "run", "-h", "web", "alpine"]) == ["macker", "run", "-h", "web", "alpine"])
        #expect(DockerGlobalFlags.install(from: ["macker", "container", "create", "-h", "web", "alpine"]) == ["macker", "container", "create", "-h", "web", "alpine"])
    }
}
