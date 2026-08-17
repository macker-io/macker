import Darwin
import Foundation

/// Docker `X-Docker-Container-Path-Stat` payload. `mode` is Go `os.FileMode`.
public struct EnginePathStat: Sendable, Equatable {
    public var name: String
    public var size: Int64
    public var mode: UInt32
    public var mtime: Date
    public var linkTarget: String

    public var isDirectory: Bool { mode & (1 << 31) != 0 }

    public init(name: String, size: Int64, mode: UInt32, mtime: Date, linkTarget: String = "") {
        self.name = name
        self.size = size
        self.mode = mode
        self.mtime = mtime
        self.linkTarget = linkTarget
    }

    public init(name: String, unixMode: UInt32, size: Int64, mtime: Date, linkTarget: String = "") {
        self.init(name: name, size: size, mode: Self.goMode(unix: unixMode), mtime: mtime, linkTarget: linkTarget)
    }

    public var dockerHeader: String {
        let payload = PathStatJSON(
            name: name,
            size: size,
            mode: mode,
            mtime: ISO8601.string(from: mtime),
            linkTarget: linkTarget
        )
        let data = (try? Self.headerEncoder.encode(payload)) ?? Data()
        return data.base64EncodedString()
    }

    public static func from(dockerHeader raw: String?) -> EnginePathStat? {
        guard let raw, let data = Data(base64Encoded: raw),
            let payload = try? JSONDecoder().decode(PathStatJSON.self, from: data)
        else { return nil }
        return EnginePathStat(
            name: payload.name,
            size: payload.size,
            mode: payload.mode,
            mtime: ISO8601.parse(payload.mtime) ?? Date(),
            linkTarget: payload.linkTarget
        )
    }

    public static func goMode(unix: UInt32) -> UInt32 {
        var mode = unix & 0o777
        switch unix & UInt32(S_IFMT) {
        case UInt32(S_IFDIR):
            mode |= 1 << 31
        case UInt32(S_IFLNK):
            mode |= 1 << 27
        case UInt32(S_IFIFO):
            mode |= 1 << 25
        case UInt32(S_IFSOCK):
            mode |= 1 << 24
        case UInt32(S_IFBLK):
            mode |= 1 << 26
        case UInt32(S_IFCHR):
            mode |= 1 << 26
            mode |= 1 << 21
        default:
            break
        }
        if unix & UInt32(S_ISUID) != 0 { mode |= 1 << 23 }
        if unix & UInt32(S_ISGID) != 0 { mode |= 1 << 22 }
        if unix & UInt32(S_ISVTX) != 0 { mode |= 1 << 20 }
        return mode
    }

    private static let headerEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

private struct PathStatJSON: Codable {
    var name: String
    var size: Int64
    var mode: UInt32
    var mtime: String
    var linkTarget: String
}

/// `docker cp` SRC/DEST: local path, or `container:path`.
public enum CopyArg: Equatable, Sendable {
    case local(String)
    case container(id: String, path: String)

    public static func parse(_ raw: String) -> CopyArg {
        if raw.hasPrefix("/") || raw == "-" {
            return .local(raw)
        }
        guard let colon = raw.firstIndex(of: ":") else {
            return .local(raw)
        }
        let head = String(raw[..<colon])
        if head.isEmpty || head.hasPrefix(".") {
            return .local(raw)
        }
        return .container(id: head, path: String(raw[raw.index(after: colon)...]))
    }

    /// Container path, or `/` when `container:` has an empty path.
    public var containerPath: String {
        switch self {
        case .container(_, let path):
            return path.isEmpty ? "/" : path
        case .local(let path):
            return path
        }
    }
}

public struct NormalizedArchivePath: Equatable, Sendable {
    public var path: String
    public var copyContents: Bool

    public var packsDirectoryContents: Bool { copyContents || path == "/" }
}

public enum ArchivePath {
    public static func normalize(_ raw: String) throws -> NormalizedArchivePath {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw EngineError.invalidArgument("path cannot be empty")
        }
        var copyContents = false
        if path.hasSuffix("/.") {
            copyContents = true
            path = String(path.dropLast(2))
            if path.isEmpty { path = "/" }
        }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        var stack: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                throw EngineError.invalidArgument("\(raw): invalid path: path escapes container root")
            }
            stack.append(String(part))
        }
        return NormalizedArchivePath(path: stack.isEmpty ? "/" : "/" + stack.joined(separator: "/"), copyContents: copyContents)
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    public static func parent(_ path: String) -> String {
        if path == "/" { return "/" }
        let parent = URL(filePath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    public static func base(_ path: String) -> String {
        path == "/" ? "." : URL(filePath: path).lastPathComponent
    }

    public static func entries(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).filter { $0.lastPathComponent != "." && $0.lastPathComponent != ".." }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    public static func replaceItem(at dest: URL, with source: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: source, to: dest)
    }

    public static func moveEntries(_ items: [URL], into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in items {
            try replaceItem(at: directory.appendingPathComponent(item.lastPathComponent), with: item)
        }
    }
}

public enum TemporaryDirectory {
    public static func with<T>(_ prefix: String, _ body: (URL) throws -> T) throws -> T {
        let url = try make(prefix)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    public static func with<T>(_ prefix: String, _ body: (URL) async throws -> T) async throws -> T {
        let url = try make(prefix)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    private static func make(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
