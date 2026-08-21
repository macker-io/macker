import Containerization
import ContainerizationEXT4
import Foundation
import SystemPackage

extension EngineManager {
    public func exportContainer(_ idOrName: String) async throws -> Data {
        let container = try requireFilesystem(idOrName)
        if container.state == "running" {
            return try await getArchive(container.id, path: "/").tar
        }
        return try await withScratch("macker-export") { work in
            let tar = work.appendingPathComponent("rootfs.tar")
            try exportOffline(container.id, to: tar)
            return try Data(contentsOf: tar)
        }
    }

    public func containerChanges(_ idOrName: String) async throws -> [EngineFSChange] {
        let container = try requireFilesystem(idOrName)
        guard container.state == "running" else {
            return try await offlineChanges(container)
        }
        return try await withExtractedRootfs(container) { root in
            try await self.extractedChanges(container, root: root)
        }
    }

    /// The changes to turn into a layer, plus a host tree holding their contents.
    /// Used by `commit` and by the builder's `RUN`.
    func withSnapshot<T>(
        _ container: EngineContainer,
        _ body: ([EngineFSChange], URL) async throws -> T
    ) async throws -> T {
        let offline = container.state == "running" ? nil : try await offlineChanges(container)
        return try await withExtractedRootfs(container) { root in
            let changes: [EngineFSChange]
            if let offline {
                changes = offline
            } else {
                changes = try await self.extractedChanges(container, root: root)
            }
            return try await body(changes, root)
        }
    }

    func snapshotBaseline(_ id: String) {
        let dest = baselineURL(id)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        let rootfs = rootfsURL(id)
        guard FileManager.default.fileExists(atPath: rootfs.path) else { return }
        guard let entries = try? FSInventory.walkEXT4(rootfs),
            let data = try? JSONEncoder().encode(entries)
        else {
            return
        }
        try? data.write(to: dest, options: .atomic)
    }

    func requireFilesystem(_ idOrName: String) throws -> EngineContainer {
        let container = try resolveContainer(idOrName)
        if container.state == "paused" {
            throw EngineError.conflict("cannot inspect the filesystem of a paused container")
        }
        if container.state == "running" {
            return container
        }
        guard FileManager.default.fileExists(atPath: rootfsURL(container.id).path) else {
            throw EngineError.conflict("container \(container.id) has no filesystem")
        }
        return container
    }

    func mountDestinations(_ container: EngineContainer) -> [String] {
        container.mounts.map(\.destination).filter { !$0.isEmpty && $0 != "/" }
    }

    func loadBaseline(_ container: EngineContainer) async throws -> [String: FSEntry] {
        let url = baselineURL(container.id)
        if let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([String: FSEntry].self, from: data)
        {
            return entries
        }
        return try await unpackImageBaseline(container.image)
    }

    func withExtractedRootfs<T>(_ container: EngineContainer, _ body: (URL) async throws -> T) async throws -> T {
        try await withScratch("macker-rootfs") { work in
            let tar = work.appendingPathComponent("rootfs.tar")
            let root = work.appendingPathComponent("root", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if container.state == "running" {
                try await getArchive(container.id, path: "/").tar.write(to: tar)
            } else {
                try exportOffline(container.id, to: tar)
            }
            try TarArchive.extract(tar, to: root)
            return try await body(root)
        }
    }

    /// Both sides are ext4 metadata, so timestamps are comparable.
    private func offlineChanges(_ container: EngineContainer) async throws -> [EngineFSChange] {
        FSInventory.diff(
            baseline: try await loadBaseline(container),
            current: try FSInventory.walkEXT4(rootfsURL(container.id))
        )
    }

    /// A live rootfs can only be read through the guest's tar, which carries no
    /// timestamps, so mtimes stay out of the comparison.
    private func extractedChanges(_ container: EngineContainer, root: URL) async throws -> [EngineFSChange] {
        FSInventory.diff(
            baseline: try await loadBaseline(container),
            current: FSInventory.walkDirectory(root, excluding: mountDestinations(container)),
            timestamps: false
        )
    }

    private func unpackImageBaseline(_ imageName: String) async throws -> [String: FSEntry] {
        let image = try await resolveImage(imageName)
        return try await withScratch("macker-image-baseline") { work in
            let dest = work.appendingPathComponent("rootfs.ext4")
            _ = try await EXT4Unpacker(capacityInBytes: Self.defaultRootfsBytes).unpack(image, for: .current, at: dest)
            return try FSInventory.walkEXT4(dest)
        }
    }

    private func exportOffline(_ id: String, to archive: URL) throws {
        let rootfs = rootfsURL(id)
        guard FileManager.default.fileExists(atPath: rootfs.path) else {
            throw EngineError.conflict("container \(id) has no filesystem")
        }
        try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path)).export(archive: FilePath(archive.path))
    }

    private func rootfsURL(_ id: String) -> URL {
        Self.runtimeURL(id: id, root: containerRoot).appendingPathComponent("rootfs.ext4")
    }

    private func baselineURL(_ id: String) -> URL {
        Self.runtimeURL(id: id, root: containerRoot).appendingPathComponent("baseline.json")
    }
}
