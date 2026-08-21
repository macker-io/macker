import CryptoKit
import Foundation

public enum TarArchive {
    public static func create(from item: URL, into archive: URL) throws {
        try run(
            ["-cf", archive.path, "-C", item.deletingLastPathComponent().path, item.lastPathComponent]
        )
    }

    /// Owner recorded in the archive. Host ownership is whatever the staged copy has;
    /// image layers override it, since a non-root host cannot restore uid/gid on extract.
    public enum Ownership: Sendable, Equatable {
        case host
        case numeric(uid: Int, gid: Int)

        public static let root = Ownership.numeric(uid: 0, gid: 0)

        var arguments: [String] {
            switch self {
            case .host:
                return []
            case .numeric(let uid, let gid):
                var args = ["--numeric-owner", "--uid", "\(uid)", "--gid", "\(gid)"]
                if uid == 0 { args += ["--uname", "root"] }
                if gid == 0 { args += ["--gname", "root"] }
                return args
            }
        }
    }

    public static func createContents(of directory: URL, into archive: URL, ownership: Ownership = .host) throws {
        try run(["-cf", archive.path] + ownership.arguments + ["-C", directory.path, "."])
    }

    /// Packs exactly `paths` (relative to `directory`), for build contexts filtered by
    /// `.dockerignore`. Directories are archived as single entries, never recursively.
    public static func create(contentsOf directory: URL, paths: [String], into archive: URL) throws {
        let list = archive.deletingLastPathComponent().appendingPathComponent("\(archive.lastPathComponent).files")
        try paths.joined(separator: "\n").appending("\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        try run(["-cf", archive.path, "--no-recursion", "-C", directory.path, "-T", list.path])
    }

    /// Pack `item` so the tar's top-level name is `name` (for `cp file.txt container:/tmp/renamed`).
    public static func create(from item: URL, named name: String, into archive: URL) throws {
        if item.lastPathComponent == name {
            try create(from: item, into: archive)
            return
        }
        try TemporaryDirectory.with("macker-pack") { work in
            let staged = work.appendingPathComponent(name)
            try FileManager.default.copyItem(at: item, to: staged)
            try create(from: staged, into: archive)
        }
    }

    public static func extract(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try run(["-xf", archive.path, "-C", directory.path])
    }

    static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return "sha256:\(hasher.finalize().map { String(format: "%02x", $0) }.joined())"
    }

    static func size(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func gzip(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: destination)
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        guard process.terminationStatus == 0 else {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.runtimeUnavailable(trimmed.isEmpty ? "gzip failed" : trimmed)
        }
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.runtimeUnavailable(trimmed.isEmpty ? "tar failed" : trimmed)
        }
    }
}
