import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation

extension EngineManager {
    public func archiveStat(_ idOrName: String, path: String) async throws -> EnginePathStat {
        let container = try requireRunningForCopy(idOrName)
        let resolved = try ArchivePath.normalize(path)
        return try await pathStat(container.id, path: resolved.path)
    }

    public func getArchive(_ idOrName: String, path: String) async throws -> (stat: EnginePathStat, tar: Data) {
        let container = try requireRunningForCopy(idOrName)
        let linux = try requireLinux(container.id)
        let resolved = try ArchivePath.normalize(path)
        let stat = try await pathStat(container.id, path: resolved.path)
        if resolved.copyContents, !stat.isDirectory {
            throw EngineError.invalidArgument("not a directory: \(resolved.path)")
        }

        return try await withScratch("macker-archive") { work in
            let copied = work.appendingPathComponent(stat.name == "." ? "root" : stat.name)
            do {
                try await linux.copyOut(from: URL(filePath: resolved.path), to: copied)
            } catch {
                throw mapArchiveError(error, path: resolved.path, containerID: container.id)
            }
            let tar = work.appendingPathComponent("archive.tar")
            if resolved.packsDirectoryContents {
                try TarArchive.createContents(of: copied, into: tar)
            } else {
                try TarArchive.create(from: copied, into: tar)
            }
            return (stat, try Data(contentsOf: tar))
        }
    }

    public func putArchive(
        _ idOrName: String,
        path: String,
        tar: Data,
        noOverwriteDirNonDir: Bool
    ) async throws {
        let container = try requireRunningForCopy(idOrName)
        let linux = try requireLinux(container.id)
        let resolved = try ArchivePath.normalize(path)
        let dest = try await pathStat(container.id, path: resolved.path)
        guard dest.isDirectory else {
            throw EngineError.invalidArgument("cannot copy to non-directory: \(resolved.path)")
        }

        try await withScratch("macker-extract") { work in
            let archive = work.appendingPathComponent("archive.tar")
            try tar.write(to: archive)
            let extracted = work.appendingPathComponent("root")
            try TarArchive.extract(archive, to: extracted)

            for item in try ArchivePath.entries(in: extracted) {
                if noOverwriteDirNonDir {
                    try await rejectTypeMismatch(
                        containerID: container.id,
                        dest: ArchivePath.join(resolved.path, item.lastPathComponent),
                        sourceIsDirectory: ArchivePath.isDirectory(item)
                    )
                }
                do {
                    try await linux.copyIn(
                        from: item,
                        to: URL(filePath: resolved.path, directoryHint: .isDirectory)
                    )
                } catch {
                    throw mapArchiveError(error, path: resolved.path, containerID: container.id)
                }
            }
        }
    }

    func requireRunningForCopy(_ idOrName: String) throws -> EngineContainer {
        let container = try resolveContainer(idOrName)
        if container.state == "paused" {
            throw EngineError.conflict("cannot copy to or from a paused container")
        }
        guard container.state == "running" else {
            throw EngineError.conflict("copy requires a running container")
        }
        return container
    }

    private func requireLinux(_ id: String) throws -> LinuxContainer {
        guard let linux = vms[id] else {
            throw EngineError.conflict("container \(id) has no running MicroVM")
        }
        return linux
    }

    private func withScratch<T>(_ prefix: String, _ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    private func pathStat(_ containerID: String, path: String) async throws -> EnginePathStat {
        let stat: ContainerizationOS.Stat
        do {
            stat = try await withGuestAgent(containerID) { agent in
                try await agent.stat(path: Self.guestAbsolutePath(containerID, containerPath: path))
            }
        } catch {
            throw mapArchiveError(error, path: path, containerID: containerID)
        }
        return EnginePathStat(
            name: ArchivePath.base(path),
            unixMode: stat.mode,
            size: stat.size,
            mtime: Date(timeIntervalSince1970: TimeInterval(stat.mtime.seconds))
        )
    }

    private func rejectTypeMismatch(containerID: String, dest: String, sourceIsDirectory: Bool) async throws {
        let existing: EnginePathStat
        do {
            existing = try await pathStat(containerID, path: dest)
        } catch let error as EngineError {
            if case .containerNotFound = error { return }
            throw error
        }
        if existing.isDirectory != sourceIsDirectory {
            throw EngineError.invalidArgument(
                "cannot overwrite \(existing.isDirectory ? "directory" : "file") \(dest) with \(sourceIsDirectory ? "directory" : "file")"
            )
        }
    }

    private func mapArchiveError(_ error: Error, path: String, containerID: String) -> EngineError {
        if let engine = error as? EngineError {
            return engine
        }
        if let containerization = error as? ContainerizationError, containerization.code == .notFound {
            return .containerNotFound("Could not find the file \(path) in container \(containerID)")
        }
        return .runtimeUnavailable(RegistryErrorMapper.describe(error))
    }

    static func guestAbsolutePath(_ id: String, containerPath: String) -> URL {
        let root = URL(filePath: guestRootfsPath(id))
        return containerPath == "/" ? root : root.appending(path: containerPath)
    }
}
