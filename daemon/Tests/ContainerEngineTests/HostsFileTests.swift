import Foundation
import Testing
@testable import ContainerEngine

struct HostsFileTests {
    @Test func includesRunningPeersAndSkipsStopped() {
        let network = "net-a"
        let selfRecord = container("aaa", name: "web", state: "created", networkID: network, ip: "172.17.0.2")
        let running = container("bbb", name: "app", state: "running", networkID: network, ip: "172.17.0.3")
        let stopped = container("ccc", name: "old", state: "exited", networkID: network, ip: "172.17.0.4")
        let otherNet = container("ddd", name: "db", state: "running", networkID: "net-b", ip: "172.18.0.2")

        let hosts = EngineManager.hostsFile(for: selfRecord, peers: [selfRecord, running, stopped, otherNet])
        let rendered = hosts.hostsFile
        #expect(rendered.contains("172.17.0.2 web"))
        #expect(rendered.contains("172.17.0.3 app"))
        #expect(!rendered.contains("old"))
        #expect(!rendered.contains("172.17.0.4"))
        #expect(!rendered.contains("db"))
    }

    @Test func includesAliasesAndShortID() {
        var peer = container("bbbbbbbbbbbbcccc", name: "app", state: "running", networkID: "net-a", ip: "172.17.0.3")
        peer.hostname = "app-host"
        peer.endpoints[0].aliases = ["app-alias"]
        let selfRecord = container("aaa", name: "web", state: "running", networkID: "net-a", ip: "172.17.0.2")
        let hosts = EngineManager.hostsFile(for: selfRecord, peers: [selfRecord, peer])
        let rendered = hosts.hostsFile
        #expect(rendered.contains("app-host"))
        #expect(rendered.contains("app-alias"))
        #expect(rendered.contains("bbbbbbbbbbbb"))
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
