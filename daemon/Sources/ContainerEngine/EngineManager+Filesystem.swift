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
        let current = try await currentInventory(container)
        let baseline = try await loadBaseline(container)
        return FSInventory.diff(baseline: baseline, current: current)
    }

    func snapshotBaseline(_ id: String) {
        let rootfs = rootfsURL(id)
        guard FileManager.default.fileExists(atPath: rootfs.path) else { return }
        guard let entries = try? FSInventory.walkEXT4(rootfs),
            let data = try? JSONEncoder().encode(entries)
        else {
            return
        }
        try? data.write(to: baselineURL(id), options: .atomic)
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

    private func currentInventory(_ container: EngineContainer) async throws -> [String: FSEntry] {
        let mounts = mountDestinations(container)
        if container.state == "running" {
            return try await withExtractedRootfs(container) { root in
                FSInventory.walkDirectory(root, excluding: mounts)
            }
        }
        return try FSInventory.walkEXT4(rootfsURL(container.id))
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
