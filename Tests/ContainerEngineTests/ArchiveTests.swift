import Darwin
import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct ArchiveTests {
    @Test func copyArgSplitsContainerAndLocal() {
        #expect(CopyArg.parse("/tmp/file") == .local("/tmp/file"))
        #expect(CopyArg.parse("./rel") == .local("./rel"))
        #expect(CopyArg.parse("file.txt") == .local("file.txt"))
        #expect(CopyArg.parse("-") == .local("-"))
        #expect(CopyArg.parse("web:/etc/hosts") == .container(id: "web", path: "/etc/hosts"))
        #expect(CopyArg.parse("web:rel") == .container(id: "web", path: "rel"))
        #expect(CopyArg.parse("./foo:bar") == .local("./foo:bar"))
        #expect(CopyArg.parse("web:").containerPath == "/")
        #expect(CopyArg.parse("web:/etc/hosts").containerPath == "/etc/hosts")
    }

    @Test func archivePathNormalizesAndRejectsEscape() throws {
        let hosts = try ArchivePath.normalize("etc/hosts")
        #expect(hosts.path == "/etc/hosts")
        #expect(!hosts.copyContents)

        let contents = try ArchivePath.normalize("/app/.")
        #expect(contents.path == "/app")
        #expect(contents.copyContents)

        let root = try ArchivePath.normalize("/")
        #expect(root.path == "/")

        #expect(throws: EngineError.self) {
            _ = try ArchivePath.normalize("../etc/passwd")
        }
        #expect(throws: EngineError.self) {
            _ = try ArchivePath.normalize("")
        }
    }

    @Test func goFileModeSetsDirectoryBit() {
        let file = EnginePathStat.goMode(unix: UInt32(S_IFREG | 0o644))
        #expect(file == 0o644)
        #expect(EnginePathStat(name: "f", size: 1, mode: file, mtime: Date()).isDirectory == false)

        let dir = EnginePathStat.goMode(unix: UInt32(S_IFDIR | 0o755))
        #expect(dir & (1 << 31) != 0)
        #expect(dir & 0o777 == 0o755)
        #expect(EnginePathStat(name: "d", size: 0, mode: dir, mtime: Date()).isDirectory)
    }

    @Test func pathStatHeaderRoundTrips() {
        let original = EnginePathStat(name: "hosts", size: 42, mode: 0o644, mtime: Date(timeIntervalSince1970: 1_700_000_000), linkTarget: "")
        let decoded = EnginePathStat.from(dockerHeader: original.dockerHeader)
        #expect(decoded?.name == "hosts")
        #expect(decoded?.size == 42)
        #expect(decoded?.mode == 0o644)
        #expect(decoded?.mtime.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test func tarRoundTripFile() throws {
        try TemporaryDirectory.with("macker-tar") { work in
            let src = work.appendingPathComponent("hello.txt")
            try "hello\n".write(to: src, atomically: true, encoding: .utf8)
            let tar = work.appendingPathComponent("a.tar")
            try TarArchive.create(from: src, named: "renamed.txt", into: tar)

            let out = work.appendingPathComponent("out")
            try TarArchive.extract(tar, to: out)
            let text = try String(contentsOf: out.appendingPathComponent("renamed.txt"), encoding: .utf8)
            #expect(text == "hello\n")
        }
    }

    @Test func directoryCopyMergesWithoutRemovingLocalFiles() throws {
        try TemporaryDirectory.with("macker-merge") { work in
            let src = work.appendingPathComponent("src/tree")
            let dest = work.appendingPathComponent("dest/tree")
            for dir in [src, dest] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try Data([1]).write(to: dest.appendingPathComponent("keep"))
            try Data([2]).write(to: dest.appendingPathComponent("update"))
            try Data([3]).write(to: src.appendingPathComponent("update"))
            try ArchivePath.moveEntries([src], into: dest.deletingLastPathComponent())
            #expect(try Data(contentsOf: dest.appendingPathComponent("keep")) == Data([1]))
            #expect(try Data(contentsOf: dest.appendingPathComponent("update")) == Data([3]))
        }
    }

    @Test func mergeDoesNotTraverseNestedDestinationSymlink() throws {
        try TemporaryDirectory.with("macker-merge-link") { work in
            let fm = FileManager.default
            let src = work.appendingPathComponent("src/tree")
            let dest = work.appendingPathComponent("dest")
            let external = work.appendingPathComponent("external")
            for dir in [src, dest, external] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try Data([1]).write(to: src.appendingPathComponent("item"))
            try fm.createSymbolicLink(at: dest.appendingPathComponent("tree"), withDestinationURL: external)
            #expect(throws: EngineError.self) {
                try ArchivePath.moveEntries([src], into: dest)
            }
            #expect(try fm.contentsOfDirectory(atPath: external.path).isEmpty)
        }
    }

    @Test func offlineCopyUsesCreationImageAfterRetag() async throws {
        try await withEngine { engine in
            try await RouterTestSupport.importTagged(engine, repo: "pinned", hello: "A")
            let id = try await engine.createContainer(.init(image: "pinned")).id
            try await RouterTestSupport.importTagged(engine, repo: "pinned", hello: "B")
            let archive = try await engine.getArchive(id, path: "/hello.txt")
            try TemporaryDirectory.with("macker-pinned") { work in
                let tar = work.appendingPathComponent("out.tar")
                try archive.tar.write(to: tar)
                try TarArchive.extract(tar, to: work)
                #expect(try String(contentsOf: work.appendingPathComponent("hello.txt"), encoding: .utf8) == "A")
            }
        }
    }

    @Test func matchArchiveRoutes() {
        #expect(Router.matchNamedContainer(method: "GET", path: "/containers/abc/archive") == .archive("abc"))
        #expect(Router.matchNamedContainer(method: "HEAD", path: "/containers/abc/archive") == .archive("abc"))
        #expect(Router.matchNamedContainer(method: "PUT", path: "/containers/abc/archive") == .archive("abc"))
        #expect(Router.matchNamedContainer(method: "GET", path: "/containers/abc/export") == .export("abc"))
        #expect(Router.matchNamedContainer(method: "GET", path: "/containers/abc/changes") == .changes("abc"))
        #expect(Router.matchNamedContainer(method: "POST", path: "/containers/abc/archive") == nil)
    }
}
