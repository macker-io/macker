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

        DockerGlobalFlags.host = "unix:///tmp/override.sock"
        #expect(try DockerGlobalFlags.socketPath(environment: [:]) == "/tmp/override.sock")

        let stripped = DockerGlobalFlags.install(from: ["macker", "--context", "other", "-H", "unix:///tmp/flag.sock", "ps", "-a"])
        #expect(stripped == ["macker", "ps", "-a"])
        #expect(DockerGlobalFlags.context == "other")
        #expect(DockerGlobalFlags.host == "unix:///tmp/flag.sock")
    }
}
