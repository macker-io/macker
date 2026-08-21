import ArgumentParser
import ContainerEngine
import Foundation

struct Cp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files/folders between a container and the local filesystem."
    )

    @Flag(name: .shortAndLong, help: "Archive mode (copy UID/GID). Ignored.")
    var archive = false

    @Flag(name: [.customShort("L"), .customLong("follow-link")], help: "Follow symlinks in the host source path.")
    var followLink = false

    @Flag(name: .shortAndLong, help: "Suppress progress. No-op; copies are not streamed.")
    var quiet = false

    @Argument(help: "SRC: `file` or `container:path`. Use `-` for stdin tar.")
    var source: String

    @Argument(help: "DEST: `file` or `container:path`. Use `-` for stdout tar.")
    var destination: String

    func run() throws {
        _ = quiet
        let src = CopyArg.parse(source)
        let dst = CopyArg.parse(destination)
        switch (src, dst) {
        case (.container, .container):
            throw CLIError.io("copying between containers is not supported")
        case (.local, .local):
            throw CLIError.io("exactly one of SRC or DEST must be `container:path`")
        case (.container(let id, _), .local(let dest)):
            try Self.fromContainer(id: id, path: src.containerPath, dest: dest)
        case (.local(let local), .container(let id, _)):
            try Self.toContainer(src: local, id: id, path: dst.containerPath, followLink: followLink, copyUIDGID: archive)
        }
    }

    private static func fromContainer(id: String, path: String, dest: String) throws {
        let response = try DaemonAPI.requireOK(DaemonAPI.get(Self.archiveURL(id: id, path: path), timeoutSeconds: 300))
        if dest == "-" {
            try FileHandle.standardOutput.write(contentsOf: response.body)
            return
        }
        try TemporaryDirectory.with("macker-cp") { work in
            let tar = work.appendingPathComponent("archive.tar")
            try response.body.write(to: tar)
            let extracted = work.appendingPathComponent("root")
            try TarArchive.extract(tar, to: extracted)
            try place(extracted: extracted, dest: dest)
        }
    }

    private static func toContainer(src: String, id: String, path: String, followLink: Bool, copyUIDGID: Bool) throws {
        if src == "-" {
            try putArchive(id: id, path: path, tar: FileHandle.standardInput.readDataToEndOfFile(), copyUIDGID: copyUIDGID)
            return
        }

        var sourceURL = URL(fileURLWithPath: src)
        var copyContents = false
        if src.hasSuffix("/.") {
            copyContents = true
            sourceURL = URL(fileURLWithPath: String(src.dropLast(2)))
        }
        if followLink {
            sourceURL = sourceURL.resolvingSymlinksInPath()
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw CLIError.io("no such file or directory: \(src)")
        }

        let (putPath, entryName) = try resolvePut(
            id: id,
            dest: path,
            sourceName: sourceURL.lastPathComponent,
            sourceIsDirectory: isDir.boolValue
        )
        try TemporaryDirectory.with("macker-cp") { work in
            let tar = work.appendingPathComponent("archive.tar")
            if copyContents {
                try TarArchive.createContents(of: sourceURL, into: tar)
            } else {
                try TarArchive.create(from: sourceURL, named: entryName, into: tar)
            }
            try putArchive(id: id, path: putPath, tar: Data(contentsOf: tar), copyUIDGID: copyUIDGID)
        }
    }

    private static func resolvePut(id: String, dest: String, sourceName: String, sourceIsDirectory: Bool) throws -> (path: String, name: String) {
        let destPath = (try? ArchivePath.normalize(dest).path) ?? dest
        let wantsDirectory = dest.hasSuffix("/") || dest.hasSuffix("/.")
        if let stat = try headStat(id: id, path: destPath) {
            if stat.isDirectory {
                return (destPath, sourceName)
            }
            if wantsDirectory {
                throw missing(id: id, path: destPath)
            }
            if sourceIsDirectory {
                throw CLIError.io("cannot copy directory to file \(destPath)")
            }
            return (ArchivePath.parent(destPath), ArchivePath.base(destPath))
        }
        if wantsDirectory {
            throw missing(id: id, path: destPath)
        }
        let parent = ArchivePath.parent(destPath)
        guard let parentStat = try headStat(id: id, path: parent), parentStat.isDirectory else {
            throw missing(id: id, path: destPath)
        }
        return (parent, ArchivePath.base(destPath))
    }

    private static func putArchive(id: String, path: String, tar: Data, copyUIDGID: Bool) throws {
        var url = Self.archiveURL(id: id, path: path)
        if copyUIDGID { url += "&copyUIDGID=1" }
        try DaemonAPI.requireOK(DaemonAPI.put(url, body: tar, timeoutSeconds: 300))
    }

    private static func headStat(id: String, path: String) throws -> EnginePathStat? {
        let response = try DaemonAPI.head(Self.archiveURL(id: id, path: path), timeoutSeconds: 30)
        if response.statusCode == 404 { return nil }
        _ = try DaemonAPI.requireOK(response)
        return EnginePathStat.from(dockerHeader: response.headers["x-docker-container-path-stat"])
    }

    private static func place(extracted: URL, dest: String) throws {
        let items = try ArchivePath.entries(in: extracted)
        let destURL = URL(fileURLWithPath: dest)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dest, isDirectory: &isDir)
        let destIsDir = dest == "." || dest.hasSuffix("/") || dest.hasSuffix("/.") || (exists && isDir.boolValue)

        if destIsDir {
            let directory = dest.hasSuffix("/.") ? destURL.deletingLastPathComponent() : destURL
            try ArchivePath.moveEntries(items, into: directory)
            return
        }
        if items.count == 1 {
            try ArchivePath.replaceItem(at: destURL, with: items[0])
            return
        }
        try ArchivePath.moveEntries(items, into: destURL)
    }

    private static func archiveURL(id: String, path: String) -> String {
        "/containers/\(DaemonAPI.path(id))/archive?path=\(DaemonAPI.query(path))"
    }

    private static func missing(id: String, path: String) -> CLIError {
        .http("Could not find the file \(path) in container \(id)")
    }
}
