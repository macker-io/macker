import Containerization
import ContainerizationEXT4
import Darwin
import Foundation

extension EngineManager {
    /// Digest-keyed unpacked ext4 so `start` does not unpack Debian-sized images every time.
    static func unpackedCacheKey(_ digest: String) -> String {
        digest.replacingOccurrences(of: ":", with: "-")
    }

    func unpackedCacheDirectory(digest: String) -> URL {
        imageStore.path
            .appendingPathComponent("unpacked", isDirectory: true)
            .appendingPathComponent(Self.unpackedCacheKey(digest), isDirectory: true)
    }

    func dropUnpackedCache(digest: String) {
        try? FileManager.default.removeItem(at: unpackedCacheDirectory(digest: digest))
    }

    /// Places a copy-on-write (or copied) rootfs in the container runtime directory.
    func prepareRootfs(id: String, image: Containerization.Image) async throws -> Mount {
        let existing = Self.runtimeURL(id: id, root: containerRoot).appendingPathComponent("rootfs.ext4")
        if FileManager.default.fileExists(atPath: existing.path) {
            // Restart: keep the container's own writable filesystem.
            return .block(format: "ext4", source: existing.path, destination: "/", options: [])
        }
        let cacheDir = unpackedCacheDirectory(digest: image.digest)
        let cached = cacheDir.appendingPathComponent("rootfs.ext4")
        let cachedBaseline = cacheDir.appendingPathComponent("baseline.json")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: cached.path) {
            let partial = cacheDir.appendingPathComponent("rootfs.ext4.partial")
            try? FileManager.default.removeItem(at: partial)
            _ = try await EXT4Unpacker(capacityInBytes: Self.defaultRootfsBytes).unpack(
                image,
                for: .current,
                at: partial
            )
            try FileManager.default.moveItem(at: partial, to: cached)
            if let entries = try? FSInventory.walkEXT4(cached),
                let data = try? JSONEncoder().encode(entries)
            {
                try? data.write(to: cachedBaseline, options: .atomic)
            }
        }

        let runtime = Self.runtimeURL(id: id, root: containerRoot)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let dest = runtime.appendingPathComponent("rootfs.ext4")
        try Self.cloneOrCopy(from: cached, to: dest)
        if FileManager.default.fileExists(atPath: cachedBaseline.path) {
            let baseline = runtime.appendingPathComponent("baseline.json")
            try? FileManager.default.removeItem(at: baseline)
            try? FileManager.default.copyItem(at: cachedBaseline, to: baseline)
        }
        return .block(format: "ext4", source: dest.path, destination: "/", options: [])
    }

    static func cloneOrCopy(from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) {
            try FileManager.default.removeItem(at: to)
        }
        let cloned = from.withUnsafeFileSystemRepresentation { src in
            to.withUnsafeFileSystemRepresentation { dst in
                guard let src, let dst else { return false }
                return clonefile(src, dst, 0) == 0
            }
        }
        if !cloned {
            try FileManager.default.copyItem(at: from, to: to)
        }
    }
}
