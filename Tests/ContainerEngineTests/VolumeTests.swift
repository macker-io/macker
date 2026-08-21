import Foundation
import Testing
@testable import ContainerEngine

struct VolumeTests {
    @Test func listFiltersByLabelAndName() async throws {
        try await withEngine { engine in
            _ = try await engine.createVolume(
                EngineVolumeCreateSpec(name: "data", labels: ["env": "test"])
            )
            _ = try await engine.createVolume(
                EngineVolumeCreateSpec(name: "other", labels: ["env": "prod"])
            )

            let labeled = await engine.listVolumes(filters: ["label": ["env=test"]])
            #expect(labeled.map(\.volume.name) == ["data"])
            let excluded = await engine.listVolumes(filters: ["label!": ["env=test"]])
            #expect(excluded.map(\.volume.name) == ["other"])
            let named = await engine.listVolumes(filters: ["name": ["dat"]])
            #expect(named.map(\.volume.name) == ["data"])
        }
    }

    @Test func createStoresLabelsAndDriverOpts() async throws {
        try await withEngine { engine in
            let created = try await engine.createVolume(
                EngineVolumeCreateSpec(name: "opted", labels: ["a": "b"], options: ["type": "tmpfs"])
            )
            #expect(created.volume.labels["a"] == "b")
            #expect(created.volume.options["type"] == "tmpfs")
            let inspected = try await engine.inspectVolume("opted")
            #expect(inspected.volume.labels["a"] == "b")
            #expect(inspected.volume.options["type"] == "tmpfs")
        }
    }

    @Test func pruneRemovesAnonymousOnlyUnlessAll() async throws {
        try await withEngine { engine in
            _ = try await engine.createVolume(EngineVolumeCreateSpec(name: "named"))
            let anonymous = try await engine.createVolume(EngineVolumeCreateSpec(anonymous: true))

            let defaultPrune = try await engine.pruneVolumes()
            #expect(defaultPrune.deleted == [anonymous.volume.name])
            let remaining = await engine.listVolumes()
            #expect(remaining.map(\.volume.name) == ["named"])

            let all = try await engine.pruneVolumes(filters: ["all": ["true"]])
            #expect(all.deleted == ["named"])
            let empty = await engine.listVolumes()
            #expect(empty.isEmpty)
        }
    }

    @Test func pruneFilterKeepsUnmatchedNamedVolume() async throws {
        try await withEngine { engine in
            _ = try await engine.createVolume(
                EngineVolumeCreateSpec(name: "keep", labels: ["env": "prod"])
            )
            _ = try await engine.createVolume(
                EngineVolumeCreateSpec(name: "drop", labels: ["env": "test"])
            )
            let pruned = try await engine.pruneVolumes(filters: ["all": ["true"], "label": ["env=test"]])
            #expect(pruned.deleted == ["drop"])
            let remaining = await engine.listVolumes()
            #expect(remaining.map(\.volume.name) == ["keep"])
        }
    }
}

