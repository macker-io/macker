import Foundation

public enum TarArchive {
    public static func create(from item: URL, into archive: URL) throws {
        try run(
            ["-cf", archive.path, "-C", item.deletingLastPathComponent().path, item.lastPathComponent]
        )
    }

    public static func createContents(of directory: URL, into archive: URL) throws {
        try run(["-cf", archive.path, "-C", directory.path, "."])
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
