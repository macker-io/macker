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
    /// Compare a live tree against the image baseline captured at start. Pass
    /// `timestamps: false` when either side went through a tar that dropped mtimes,
    /// which would otherwise report every file in the image as modified.
    public static func diff(
        baseline: [String: FSEntry],
        current: [String: FSEntry],
        timestamps: Bool = true
    ) -> [EngineFSChange] {
        diff(baseline: baseline, current: current, timestamps: timestamps) { _, _ in true }
    }

    static func diff(
        baseline: [String: FSEntry],
        current: [String: FSEntry],
        timestamps: Bool,
        equalFileContents: (String, Int64) throws -> Bool
    ) rethrows -> [EngineFSChange] {
        var changes: [EngineFSChange] = []
        for path in Set(baseline.keys).union(current.keys).sorted() where path != "/" {
            switch (baseline[path], current[path]) {
            case (nil, .some):
                changes.append(EngineFSChange(path: path, kind: .add))
            case (.some, nil):
                changes.append(EngineFSChange(path: path, kind: .delete))
            case (let left?, let right?) where changed(left, right, timestamps: timestamps):
                changes.append(EngineFSChange(path: path, kind: .modify))
            case (let left?, .some) where left.kind == .file && left.size > 0:
                if try !equalFileContents(path, left.size) {
                    changes.append(EngineFSChange(path: path, kind: .modify))
                }
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

    /// A directory enumeration reports paths under the real root (`/private/var/…`)
    /// while callers hold the unresolved URL (`/var/…`). Standardizing the entry is not
    /// an option: it silently leaves dangling symlinks — which an image rootfs is full
    /// of — spelled the other way, so accept either spelling of the root instead.
    public static func containerPath(for url: URL, root: URL) -> String? {
        relativePath(url.path, under: rootPrefixes(root))
    }

    static func rootPrefixes(_ root: URL) -> [String] {
        let path = root.path
        let real = realpath(path)
        return real == path ? [path] : [path, real]
    }

    static func relativePath(_ full: String, under bases: [String]) -> String? {
        for base in bases {
            if full == base { return nil }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            guard full.hasPrefix(prefix) else { continue }
            return "/" + String(full.dropFirst(prefix.count))
        }
        return nil
    }

    /// `URL.resolvingSymlinksInPath` strips `/private` back off, which is the opposite
    /// of what an enumeration hands back.
    private static func realpath(_ path: String) -> String {
        guard let resolved = Foundation.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func hostURL(root: URL, path: String) -> URL {
        URL(filePath: root.path + (path.hasPrefix("/") ? path : "/" + path))
    }

    public static func walkDirectory(_ root: URL, excluding mounts: [String] = []) -> [String: FSEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return [:]
        }

        var entries: [String: FSEntry] = [:]
        let prefixes = rootPrefixes(root)
        while let url = enumerator.nextObject() as? URL {
            guard let rel = relativePath(url.path, under: prefixes), !shouldSkip(rel) else { continue }
            if mounts.contains(rel) {
                enumerator.skipDescendants()
            }
            if isExcluded(rel, mounts: mounts) { continue }
            guard let entry = stat(url) else { continue }
            entries[rel] = entry
        }
        return entries
    }

    /// Compare the extracted regular file against the immutable image, not the active VM disk.
    static func equalFileContents(path: String, size: Int64, root: URL, image: EXT4.EXT4Reader) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: hostURL(root: root, path: path))
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            let count = Int(min(1 << 20, size - offset))
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                throw EngineError.exportFailed("incomplete snapshot file: \(path)")
            }
            let original = try image.readFile(at: FilePath(path), offset: UInt64(offset), count: chunk.count, followSymlinks: false)
            guard original.count == chunk.count else {
                throw EngineError.exportFailed("incomplete image file: \(path)")
            }
            if original != chunk { return false }
            offset += Int64(chunk.count)
        }
        return true
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

    /// EXT4 inodes carry the full `st_mode`; a host directory walk only sees the
    /// permission bits, so comparisons mask off the file type. Symlink permissions
    /// and mtimes do not survive a host extraction either, so only the target
    /// length is compared for them.
    private static func changed(_ left: FSEntry, _ right: FSEntry, timestamps: Bool) -> Bool {
        if left.kind != right.kind { return true }
        let permissions = left.mode & 0o7777 != right.mode & 0o7777
        switch left.kind {
        case .directory:
            return permissions
        case .symlink:
            return left.size != right.size
        case .file, .other:
            if timestamps, left.mtime != right.mtime { return true }
            return left.size != right.size || permissions
        }
    }

    private static func shouldSkip(_ path: String) -> Bool {
        path == "/lost+found" || path.hasPrefix("/lost+found/")
    }

    /// `lstat`, not `URL.resourceValues`: image rootfs trees are full of absolute
    /// symlinks (`/bin/cat` → `/bin/busybox`) that dangle once extracted to a host
    /// directory, and resource values for a dangling link fail outright.
    private static func stat(_ url: URL) -> FSEntry? {
        var info = Foundation.stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FSEntry(
            kind: FSEntry.Kind(unixMode: info.st_mode),
            size: Int64(info.st_size),
            mode: info.st_mode,
            mtime: Int64(info.st_mtimespec.tv_sec)
        )
    }
}
