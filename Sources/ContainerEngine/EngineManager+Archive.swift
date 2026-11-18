import Containerization
import ContainerizationError
import ContainerizationArchive
import ContainerizationOS
import os
import Foundation

extension EngineManager {
    public func archiveStat(_ idOrName: String, path: String) async throws -> EnginePathStat {
        let target = try resolveContainer(idOrName)
        if Self.isStopped(target) {
            return try await offlineArchive(target, path: path, packing: false).stat
        }
        let container = try requireRunningForCopy(idOrName)
        let resolved = try ArchivePath.normalize(path)
        return try await pathStat(container.id, path: resolved.path)
    }

    public func getArchive(_ idOrName: String, path: String) async throws -> (stat: EnginePathStat, tar: Data) {
        let target = try resolveContainer(idOrName)
        if Self.isStopped(target) {
            return try await offlineArchive(target, path: path, packing: true)
        }
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
        let target = try resolveContainer(idOrName)
        if target.state == "created" || target.state == "exited" || target.state == "dead" {
            // Docker writes into a stopped container's filesystem. Its rootfs is only mounted
            // inside a running MicroVM, so the archive is applied at the next start, before
            // the main process runs.
            try stagePendingArchive(target.id, path: try ArchivePath.normalize(path).path, tar: tar)
            return
        }
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
                        to: URL(filePath: resolved.path, directoryHint: .isDirectory),
                        mode: Self.fileMode(item)
                    )
                } catch {
                    throw mapArchiveError(error, path: resolved.path, containerID: container.id)
                }
            }
        }
    }

    static let pendingArchivesDirectory = "pending-archives"

    static func isStopped(_ container: EngineContainer) -> Bool {
        ["created", "exited", "dead"].contains(container.state)
    }

    /// `docker cp` out of a stopped container: read its root filesystem image directly. A
    /// container that never started gets its filesystem materialized from the image first.
    private func offlineArchive(_ container: EngineContainer, path: String, packing: Bool) async throws -> (stat: EnginePathStat, tar: Data) {
        let resolved = try ArchivePath.normalize(path)
        let rootfs = Self.runtimeURL(id: container.id, root: containerRoot).appendingPathComponent("rootfs.ext4")
        if !FileManager.default.fileExists(atPath: rootfs.path) {
            _ = try await prepareRootfs(id: container.id, image: try await resolveImage(container.image))
        }
        return try await withExtractedRootfs(container) { root in
            let item = resolved.path == "/" ? root : root.appendingPathComponent(String(resolved.path.dropFirst()))
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.path) else {
                throw EngineError.containerNotFound("Could not find the file \(resolved.path) in container \(container.name)")
            }
            let type = attributes[.type] as? FileAttributeType
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
            let unixType: UInt32 = type == .typeDirectory ? 0o040000 : type == .typeSymbolicLink ? 0o120000 : 0o100000
            let stat = EnginePathStat(
                name: ArchivePath.base(resolved.path),
                unixMode: unixType | permissions,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                mtime: (attributes[.modificationDate] as? Date) ?? Date(),
                linkTarget: type == .typeSymbolicLink ? ((try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? "") : ""
            )
            guard packing else { return (stat, Data()) }
            if resolved.copyContents, !stat.isDirectory {
                throw EngineError.invalidArgument("not a directory: \(resolved.path)")
            }
            return try await self.withScratch("macker-archive") { work in
                let tar = work.appendingPathComponent("archive.tar")
                if resolved.packsDirectoryContents {
                    try TarArchive.createContents(of: item, into: tar)
                } else {
                    try TarArchive.create(from: item, into: tar)
                }
                return (stat, try Data(contentsOf: tar))
            }
        }
    }

    private func pendingArchivesURL(_ id: String) -> URL {
        Self.runtimeURL(id: id, root: containerRoot)
            .appendingPathComponent(Self.pendingArchivesDirectory, isDirectory: true)
    }

    private func stagePendingArchive(_ id: String, path: String, tar: Data) throws {
        let dir = pendingArchivesURL(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let entry = dir.appendingPathComponent(String(format: "%06d", existing.count), isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try tar.write(to: entry.appendingPathComponent("archive.tar"))
        try Data(path.utf8).write(to: entry.appendingPathComponent("destination"))
    }

    /// Applies archives staged by ``putArchive`` while the container was stopped. Runs between
    /// VM create (rootfs mounted) and process start, so the workload sees the files at once.
    func applyPendingArchives(_ id: String, to linux: LinuxContainer) async throws {
        let dir = pendingArchivesURL(id)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path), !entries.isEmpty else {
            return
        }
        for name in entries.sorted() {
            let entry = dir.appendingPathComponent(name, isDirectory: true)
            let destination = (try? String(contentsOf: entry.appendingPathComponent("destination"), encoding: .utf8)) ?? "/"
            try await withScratch("macker-extract") { work in
                let extracted = work.appendingPathComponent("root")
                try TarArchive.extract(entry.appendingPathComponent("archive.tar"), to: extracted)
                for item in try ArchivePath.entries(in: extracted) {
                    let guestPath = Self.guestAbsolutePath(id, containerPath: destination)
                        .appendingPathComponent(item.lastPathComponent)
                    do {
                        try await Self.copyIntoCreatedVM(linux, from: item, guestPath: guestPath)
                    } catch {
                        throw mapArchiveError(error, path: destination, containerID: id)
                    }
                }
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private static let copyPorts = CopyPortCounter()

    /// `LinuxContainer.copyIn` requires a started container; this is the same vsock transfer
    /// against a created VM whose rootfs is already mounted.
    private static func copyIntoCreatedVM(_ linux: LinuxContainer, from item: URL, guestPath: URL) async throws {
        let isDirectory = ArchivePath.isDirectory(item)
        let mode = fileMode(item)
        try await linux.withVirtualMachineInstance { vm in
            let port = copyPorts.next()
            let listener = try vm.listen(port)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    guard let vz = vm as? VZVirtualMachineInstance else {
                        throw EngineError.runtimeUnavailable("guest agent is unavailable")
                    }
                    let agent = try await vz.dialAgent()
                    defer { Task { try? await agent.close() } }
                    try await agent.copy(
                        direction: .copyIn,
                        guestPath: guestPath,
                        vsockPort: port,
                        mode: mode,
                        createParents: true,
                        isArchive: isDirectory
                    )
                }
                group.addTask {
                    guard let conn = await listener.first(where: { _ in true }) else {
                        throw EngineError.runtimeUnavailable("copy: vsock connection not established")
                    }
                    try listener.finish()
                    defer { conn.closeFile() }
                    if isDirectory {
                        let writer = try ArchiveWriter(configuration: .init(format: .pax, filter: .gzip))
                        try writer.open(fileDescriptor: conn.fileDescriptor)
                        try writer.archiveDirectory(item)
                        try writer.finishEncoding()
                    } else {
                        let source = try FileHandle(forReadingFrom: item)
                        defer { try? source.close() }
                        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                            try conn.write(contentsOf: chunk)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    static func fileMode(_ url: URL) -> UInt32 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
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

    func withScratch<T>(_ prefix: String, _ body: (URL) async throws -> T) async throws -> T {
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

/// Host vsock ports for pre-start copies; far from `LinuxContainer`'s own range (0x1000_0000+).
final class CopyPortCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: UInt32(0x3000_0000))

    func next() -> UInt32 {
        value.withLock { current in
            current &+= 1
            return current
        }
    }
}
