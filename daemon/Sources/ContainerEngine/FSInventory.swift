import ContainerizationEXT4
import Foundation
import SystemPackage

/// One path in a container filesystem snapshot. Paths are absolute (`/etc/hosts`).
public struct FSEntry: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case file
        case directory
        case symlink
        case other

        init(unixMode: UInt16) {
            switch unixMode & 0xF000 {
            case 0x4000: self = .directory
            case 0x8000: self = .file
            case 0xA000: self = .symlink
            default: self = .other
            }
        }
    }

    public var kind: Kind
    public var size: Int64
    public var mode: UInt16
    public var mtime: Int64

    public init(kind: Kind, size: Int64, mode: UInt16, mtime: Int64) {
        self.kind = kind
        self.size = size
        self.mode = mode
        self.mtime = mtime
    }
}

/// Docker `GET /containers/{id}/changes`: 0 = modify, 1 = add, 2 = delete.
public struct EngineFSChange: Sendable, Equatable {
    public enum Kind: Int, Sendable, Equatable {
        case modify = 0
        case add = 1
        case delete = 2

        public var letter: String {
            switch self {
            case .modify: return "C"
            case .add: return "A"
            case .delete: return "D"
            }
        }
    }

    public var path: String
    public var kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

public enum FSInventory {
    /// Compare a live tree against the image baseline captured at start.
    public static func diff(baseline: [String: FSEntry], current: [String: FSEntry]) -> [EngineFSChange] {
        var changes: [EngineFSChange] = []
        for path in Set(baseline.keys).union(current.keys).sorted() where path != "/" {
            switch (baseline[path], current[path]) {
            case (nil, .some):
                changes.append(EngineFSChange(path: path, kind: .add))
            case (.some, nil):
                changes.append(EngineFSChange(path: path, kind: .delete))
            case (let left?, let right?) where changed(left, right):
                changes.append(EngineFSChange(path: path, kind: .modify))
            default:
                break
            }
        }
        return changes
    }

    /// Volume/bind destinations themselves stay (they came from the image); their contents do not.
    public static func isExcluded(_ path: String, mounts: [String]) -> Bool {
        mounts.contains { mount in
            guard mount != "/", path != mount else { return false }
            let prefix = mount.hasSuffix("/") ? mount : mount + "/"
            return path.hasPrefix(prefix)
        }
    }

    /// Whiteout path for a deleted file (`/usr/bin/foo` → `/usr/bin/.wh.foo`).
    public static func whiteoutPath(for path: String) -> String {
        ArchivePath.join(ArchivePath.parent(path), ".wh.\(ArchivePath.base(path))")
    }

    /// Deletes whose parent is also deleted are covered by the parent's whiteout.
    public static func topmostDeletes(_ paths: [String]) -> [String] {
        let deleted = Set(paths)
        return paths.filter { path in
            var parent = ArchivePath.parent(path)
            while parent != "/" {
                if deleted.contains(parent) { return false }
                parent = ArchivePath.parent(parent)
            }
            return true
        }
    }

    public static func containerPath(for url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full == rootPath { return nil }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return "/" + String(full.dropFirst(prefix.count))
    }

    public static func hostURL(root: URL, path: String) -> URL {
        URL(filePath: root.path + (path.hasPrefix("/") ? path : "/" + path))
    }

    public static func walkDirectory(_ root: URL, excluding mounts: [String] = []) -> [String: FSEntry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceTypeKey,
            ],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return [:]
        }

        var entries: [String: FSEntry] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard let rel = containerPath(for: url, root: root), !shouldSkip(rel) else { continue }
            if mounts.contains(rel) {
                enumerator.skipDescendants()
            }
            if isExcluded(rel, mounts: mounts) { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceTypeKey,
            ]) else {
                continue
            }
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            entries[rel] = FSEntry(
                kind: kind(from: values),
                size: Int64(values.fileSize ?? 0),
                mode: (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
                mtime: Int64((values.contentModificationDate ?? Date.distantPast).timeIntervalSince1970)
            )
        }
        return entries
    }

    public static func walkEXT4(_ url: URL) throws -> [String: FSEntry] {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(url.path))
        var entries: [String: FSEntry] = [:]
        try walkEXT4(reader, path: "/", into: &entries)
        return entries
    }

    public static func packLayer(from root: URL, changes: [EngineFSChange], into directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in topmostDeletes(changes.filter { $0.kind == .delete }.map(\.path)) {
            let whiteout = hostURL(root: directory, path: whiteoutPath(for: path))
            try fm.createDirectory(at: whiteout.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: whiteout.path, contents: Data())
        }
        for change in changes where change.kind != .delete {
            let source = hostURL(root: root, path: change.path)
            let dest = hostURL(root: directory, path: change.path)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try stage(source, to: dest)
        }
    }

    private static func walkEXT4(_ reader: EXT4.EXT4Reader, path: String, into entries: inout [String: FSEntry]) throws {
        let names: [String]
        do {
            names = try reader.listDirectory(FilePath(path))
        } catch {
            return
        }
        for name in names {
            let child = ArchivePath.join(path, name)
            if shouldSkip(child) { continue }
            let inode: EXT4.Inode
            do {
                inode = try reader.stat(FilePath(child), followSymlinks: false).inode
            } catch {
                continue
            }
            let kind = FSEntry.Kind(unixMode: inode.mode)
            let size = Int64(UInt64(inode.sizeLow) | (UInt64(inode.sizeHigh) << 32))
            entries[child] = FSEntry(kind: kind, size: size, mode: inode.mode, mtime: Int64(inode.mtime))
            if kind == .directory {
                try walkEXT4(reader, path: child, into: &entries)
            }
        }
    }

    /// Directories are created empty so a mode-only change does not copy unchanged children.
    private static func stage(_ source: URL, to dest: URL) throws {
        let fm = FileManager.default
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink != true, values?.isDirectory == true {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            if let perms = try? fm.attributesOfItem(atPath: source.path)[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: dest.path)
            }
            return
        }
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
    }

    private static func changed(_ left: FSEntry, _ right: FSEntry) -> Bool {
        if left.kind != right.kind { return true }
        if left.kind == .directory { return left.mode != right.mode }
        return left.size != right.size || left.mtime != right.mtime || left.mode != right.mode
    }

    private static func shouldSkip(_ path: String) -> Bool {
        path == "/lost+found" || path.hasPrefix("/lost+found/")
    }

    private static func kind(from values: URLResourceValues) -> FSEntry.Kind {
        if values.isSymbolicLink == true { return .symlink }
        if values.isDirectory == true { return .directory }
        if values.fileResourceType == .regular { return .file }
        return .other
    }
}
