import Foundation
import Testing
@testable import ContainerEngine

struct HostsFileTests {
    @Test func keepsOnlyLocalhostEntries() {
        let network = "net-a"
        let selfRecord = container("aaa", name: "web", state: "created", networkID: network, ip: "172.17.0.2")
        let running = container("bbb", name: "app", state: "running", networkID: network, ip: "172.17.0.3")

        let hosts = EngineManager.hostsFile(for: selfRecord, peers: [selfRecord, running])
        let rendered = hosts.hostsFile
        #expect(rendered.contains("127.0.0.1"))
        #expect(rendered.contains("localhost"))
        #expect(!rendered.contains("172.17.0.2"))
        #expect(!rendered.contains("172.17.0.3"))
        #expect(!rendered.contains(" web"))
        #expect(!rendered.contains(" app"))
    }

    private func container(
        _ id: String,
        name: String,
        state: String,
        networkID: String,
        ip: String
    ) -> EngineContainer {
        EngineContainer(
            id: id,
            name: name,
            image: "alpine",
            imageID: "img",
            command: ["sleep", "inf"],
            env: [],
            workingDir: "/",
            user: "",
            hostname: name,
            labels: [:],
            state: state,
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
            mounts: [],
            endpoints: [
                EngineEndpoint(
                    networkID: networkID,
                    networkName: "bridge",
                    ipv4Address: ip,
                    ipv4Prefix: 16,
                    gateway: "172.17.0.1",
                    macAddress: "",
                    aliases: []
                )
            ]
        )
    }
}
