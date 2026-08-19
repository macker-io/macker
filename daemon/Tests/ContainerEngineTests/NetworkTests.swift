import Foundation
import Testing
@testable import ContainerEngine

struct NetworkTests {
    @Test func listFiltersByLabelDriverTypeAndDangling() async throws {
        try await withEngine { engine in
            _ = try await engine.createNetwork(
                EngineNetworkCreateSpec(name: "front", labels: ["env": "test"])
            )
            _ = try await engine.createNetwork(
                EngineNetworkCreateSpec(name: "back", labels: ["env": "prod"])
            )

            let labeled = await engine.listNetworks(filters: ["label": ["env=test"]])
            #expect(labeled.map(\.network.name) == ["front"])
            let excluded = await engine.listNetworks(filters: ["label!": ["env=test"]])
            #expect(!excluded.contains { $0.network.name == "front" })
            let named = await engine.listNetworks(filters: ["name": ["fro"]])
            #expect(named.map(\.network.name) == ["front"])
            let custom = await engine.listNetworks(filters: ["type": ["custom"]])
            #expect(Set(custom.map(\.network.name)) == ["back", "front"])
            let builtin = await engine.listNetworks(filters: ["type": ["builtin"]])
            #expect(Set(builtin.map(\.network.name)) == ["bridge", "host", "none"])
            let dangling = await engine.listNetworks(filters: ["dangling": ["true"], "type": ["custom"]])
            #expect(Set(dangling.map(\.network.name)) == ["back", "front"])
            let byDriver = await engine.listNetworks(filters: ["driver": ["bridge"], "type": ["custom"]])
            #expect(Set(byDriver.map(\.network.name)) == ["back", "front"])
        }
    }

    @Test func createStoresIPAMOptionsAndDriverOpts() async throws {
        try await withEngine { engine in
            let created = try await engine.createNetwork(
                EngineNetworkCreateSpec(
                    name: "ranged",
                    labels: ["a": "b"],
                    options: ["com.docker.network.bridge.enable_icc": "false"],
                    subnet: "172.20.0.0/16",
                    gateway: "172.20.0.1",
                    ipRange: "172.20.0.128/25",
                    auxiliaryAddresses: ["dns": "172.20.0.129"],
                    ipamOptions: ["foo": "bar"]
                )
            )
            #expect(created.network.subnet == "172.20.0.0/16")
            #expect(created.network.gateway == "172.20.0.1")
            #expect(created.network.ipRange == "172.20.0.128/25")
            #expect(created.network.auxiliaryAddresses["dns"] == "172.20.0.129")
            #expect(created.network.labels["a"] == "b")
            #expect(created.network.options["com.docker.network.bridge.enable_icc"] == "false")
            #expect(created.network.ipamOptions["foo"] == "bar")

            let inspected = try await engine.inspectNetwork("ranged")
            #expect(inspected.network.ipRange == "172.20.0.128/25")
            #expect(inspected.network.auxiliaryAddresses["dns"] == "172.20.0.129")

            await engine.prepareGateway()
            let allocated = try await engine.networkGateway.allocate(created.network.id, key: "c1")
            #expect(allocated.description == "172.20.0.128")
            let second = try await engine.networkGateway.allocate(created.network.id, key: "c2")
            #expect(second.description == "172.20.0.130")
        }
    }

    @Test func createRejectsUnsupportedIPAMAndIPv6() async throws {
        try await withEngine { engine in
            await #expect(throws: EngineError.self) {
                _ = try await engine.createNetwork(EngineNetworkCreateSpec(name: "v6", enableIPv6: true))
            }
            await #expect(throws: EngineError.self) {
                _ = try await engine.createNetwork(EngineNetworkCreateSpec(name: "no4", enableIPv4: false))
            }
            await #expect(throws: EngineError.self) {
                _ = try await engine.createNetwork(EngineNetworkCreateSpec(name: "ipam", ipamDriver: "other"))
            }
            await #expect(throws: EngineError.self) {
                _ = try await engine.createNetwork(
                    EngineNetworkCreateSpec(name: "bad-range", subnet: "172.21.0.0/16", ipRange: "10.0.0.0/24")
                )
            }
        }
    }

    @Test func pruneFilterKeepsUnmatchedNetwork() async throws {
        try await withEngine { engine in
            _ = try await engine.createNetwork(
                EngineNetworkCreateSpec(name: "keep", labels: ["env": "prod"])
            )
            _ = try await engine.createNetwork(
                EngineNetworkCreateSpec(name: "drop", labels: ["env": "test"])
            )
            let pruned = try await engine.pruneNetworks(filters: ["label": ["env=test"]])
            #expect(pruned.deleted == ["drop"])
            let remaining = await engine.listNetworks(filters: ["type": ["custom"]])
            #expect(remaining.map(\.network.name) == ["keep"])
        }
    }

    @Test func deleteMissingAndBuiltinNetworks() async throws {
        try await withEngine { engine in
            await #expect(throws: EngineError.self) {
                try await engine.deleteNetwork("no-such-net")
            }
            await #expect(throws: EngineError.self) {
                try await engine.deleteNetwork("bridge")
            }
        }
    }
}

private func withEngine(_ body: (EngineManager) async throws -> Void) async throws {
    try await TemporaryDirectory.with("macker-network") { dir in
        try await body(try EngineManager(storePath: dir))
    }
}
