import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct PortBindingParseTests {
    @Test func parsePublishSpecs() throws {
        let containerOnly = try EnginePortBinding.parsePublish("80")
        #expect(containerOnly.hostIP == "")
        #expect(containerOnly.hostPort == 0)
        #expect(containerOnly.containerPort == 80)
        #expect(containerOnly.protocolName == "tcp")
        #expect(containerOnly.dockerKey == "80/tcp")

        let mapped = try EnginePortBinding.parsePublish("8080:80")
        #expect(mapped.hostPort == 8080)
        #expect(mapped.containerPort == 80)

        let ephemeral = try EnginePortBinding.parsePublish(":80")
        #expect(ephemeral.hostPort == 0)
        #expect(ephemeral.containerPort == 80)

        let bound = try EnginePortBinding.parsePublish("127.0.0.1:8080:80/udp")
        #expect(bound.hostIP == "127.0.0.1")
        #expect(bound.hostPort == 8080)
        #expect(bound.containerPort == 80)
        #expect(bound.protocolName == "udp")
        #expect(bound.dockerKey == "80/udp")
    }

    @Test func parsePublishRejectsBadInput() {
        #expect(throws: EngineError.self) { _ = try EnginePortBinding.parsePublish("") }
        #expect(throws: EngineError.self) { _ = try EnginePortBinding.parsePublish("80/sctp") }
        #expect(throws: EngineError.self) { _ = try EnginePortBinding.parsePublish("65536:80") }
        #expect(throws: EngineError.self) { _ = try EnginePortBinding.parsePublish("1:2:3:4") }
    }

    @Test func parseExposedKeys() throws {
        let implied = try EnginePortBinding.parseExposed("80")
        #expect(implied.containerPort == 80)
        #expect(implied.hostPort == 80)
        #expect(implied.protocolName == "tcp")

        let udp = try EnginePortBinding.parseExposed("53/UDP")
        #expect(udp.containerPort == 53)
        #expect(udp.protocolName == "udp")
    }

    @Test func parseExposedRejectsBadInput() {
        #expect(throws: EngineError.self) { _ = try EnginePortBinding.parseExposed("") }
        #expect(throws: EngineError.self) { _ = try EnginePortBinding.parseExposed("0") }
        #expect(throws: EngineError.self) { _ = try EnginePortBinding.parseExposed("80/sctp") }
    }

    @Test func mergingKeepsOneBindingPerDockerKey() throws {
        let merged = EnginePortBinding.merging(
            [EnginePortBinding(hostIP: "", hostPort: 8080, containerPort: 80)],
            [
                EnginePortBinding(hostIP: "127.0.0.1", hostPort: 8081, containerPort: 80),
                EnginePortBinding(hostIP: "", hostPort: 8443, containerPort: 443),
            ]
        )
        #expect(merged.map(\.dockerKey) == ["80/tcp", "443/tcp"])
        #expect(merged[0].hostPort == 8081)
    }
}

struct PortMappingTests {
    @Test func listsAllMappingsSorted() throws {
        let bindings = [
            EnginePortBinding(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80),
            EnginePortBinding(hostIP: "127.0.0.1", hostPort: 8443, containerPort: 443),
        ]
        #expect(
            try EnginePortBinding.dockerPortLines(bindings, privatePort: nil, container: "web") == [
                "443/tcp -> 127.0.0.1:8443",
                "80/tcp -> 0.0.0.0:8080",
            ]
        )
    }

    @Test func specificPortPrintsHostAddresses() throws {
        let bindings = [
            EnginePortBinding(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80),
            EnginePortBinding(hostIP: "::", hostPort: 8080, containerPort: 80),
        ]
        #expect(
            try EnginePortBinding.dockerPortLines(bindings, privatePort: "80", container: "web") == [
                "0.0.0.0:8080",
                "[::]:8080",
            ]
        )
        #expect(
            try EnginePortBinding.dockerPortLines(bindings, privatePort: "80/TCP", container: "web")
                == ["0.0.0.0:8080", "[::]:8080"]
        )
    }

    @Test func keepsMultipleHostsUnlikeMerging() throws {
        let bindings = [
            EnginePortBinding(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80),
            EnginePortBinding(hostIP: "127.0.0.1", hostPort: 8081, containerPort: 80),
        ]
        #expect(EnginePortBinding.uniqued(bindings).count == 1)
        #expect(
            try EnginePortBinding.dockerPortLines(bindings, privatePort: "80", container: "web")
                == ["0.0.0.0:8080", "127.0.0.1:8081"]
        )
    }

    @Test func emptyBindingsPrintNothing() throws {
        #expect(try EnginePortBinding.dockerPortLines([], privatePort: nil, container: "web").isEmpty)
    }

    @Test func missingPublicPortErrors() {
        #expect(throws: EngineError.self) {
            _ = try EnginePortBinding.dockerPortLines([], privatePort: "80", container: "web")
        }
    }

    @Test func invalidPrivatePortErrors() throws {
        #expect(throws: EngineError.self) {
            _ = try EnginePortBinding.parsePrivatePortKey("http")
        }
        #expect(throws: EngineError.self) {
            _ = try EnginePortBinding.parsePrivatePortKey("65536")
        }
        #expect(try EnginePortBinding.parsePrivatePortKey("80/") == "80/tcp")
        #expect(try EnginePortBinding.parsePrivatePortKey("443/udp") == "443/udp")
    }

    @Test func inspectJSONFeedsPortCommand() throws {
        var record = EngineContainer(
            id: "abc",
            name: "web",
            image: "nginx",
            imageID: "img",
            command: ["nginx"],
            env: [],
            workingDir: "/",
            user: "",
            hostname: "web",
            labels: [:],
            state: "running",
            created: Date(),
            startedAt: nil,
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
        record.portBindings = [
            EnginePortBinding(hostIP: "", hostPort: 18080, containerPort: 80),
            EnginePortBinding(hostIP: "127.0.0.1", hostPort: 8443, containerPort: 443),
        ]
        let data = try JSONEncoder().encode(DockerContainerInspect(record))
        let inspect = try JSONDecoder().decode(DockerPortMapping.Inspect.self, from: data)
        #expect(
            try DockerPortMapping.lines(from: inspect, privatePort: nil, container: "web") == [
                "443/tcp -> 127.0.0.1:8443",
                "80/tcp -> 0.0.0.0:18080",
            ]
        )
        #expect(
            try DockerPortMapping.lines(from: inspect, privatePort: "80", container: "web")
                == ["0.0.0.0:18080"]
        )
    }

    @Test func inspectSkipsNullUnpublishedPorts() throws {
        let json = Data(#"{"NetworkSettings":{"Ports":{"80/tcp":null,"443/tcp":[]}}}"#.utf8)
        let inspect = try JSONDecoder().decode(DockerPortMapping.Inspect.self, from: json)
        #expect(inspect.publishedBindings.isEmpty)
        #expect(try DockerPortMapping.lines(from: inspect, privatePort: nil, container: "web").isEmpty)
    }
}
