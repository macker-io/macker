import Foundation
import Testing
@testable import ContainerEngine

struct VolumeTests {
    @Test func missingNetworkDoesNotLeaveAnImageDeclaredVolume() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-volume-image") { work in
                _ = try await collectDigest(await engine.importImage(
                    spec: .init(source: "-", repo: "declared", tag: "v1", changes: ["VOLUME /data"]),
                    archive: try pack(hello: "a", in: work)
                ))
                await #expect(throws: EngineError.self) {
                    _ = try await engine.createContainer(.init(image: "declared:v1", networkMode: "missing"))
                }
                #expect(await engine.listVolumes().isEmpty)
            }
        }
    }

    @Test func failedCreateRollsBackOnlyItsNewAnonymousVolumes() async throws {
        try await TemporaryDirectory.with("macker-create-rollback") { store in
            let engine = try EngineManager(storePath: store)
            try await RouterTestSupport.importTagged(engine, repo: "rollback", tag: "v1")
            let existing = try await engine.createVolume(.init(anonymous: true)).volume.name
            var requests: [EngineVolumeRequest] = [
                .init(type: "volume", source: existing, destination: "/existing"),
                .init(type: "volume", source: "named", destination: "/named"),
                .init(type: "volume", source: "", destination: "/new-a"),
                .init(type: "volume", source: "", destination: "/new-b"),
            ]
            requests.append(.init(type: "volume", source: "invalid/name", destination: "/last"))
            await #expect(throws: EngineError.self) {
                _ = try await engine.createContainer(.init(image: "rollback:v1", volumeRequests: requests))
            }
            let kept = Set([existing, "named"])
            #expect(Set(await engine.listVolumes().map(\.volume.name)) == kept)

            // Fail after all mounts resolve, at the point of persisting the container record.
            let root = store.appendingPathComponent("containers")
            try FileManager.default.removeItem(at: root)
            try Data().write(to: root)
            requests.removeLast()
            await #expect(throws: (any Error).self) {
                _ = try await engine.createContainer(.init(image: "rollback:v1", volumeRequests: requests))
            }
            #expect(Set(await engine.listVolumes().map(\.volume.name)) == kept)
            let onDisk = try FileManager.default.contentsOfDirectory(atPath: store.appendingPathComponent("volumes").path)
            #expect(Set(onDisk) == kept)
        }
    }

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

