import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct BuildStepTests {
    @Test func cacheKeyTracksParentInstructionAndInputs() {
        let base = BuildCache.key(parent: "sha256:aaa", instruction: "RUN make")
        #expect(base == BuildCache.key(parent: "sha256:aaa", instruction: "RUN make"))
        #expect(base != BuildCache.key(parent: "sha256:bbb", instruction: "RUN make"))
        #expect(base != BuildCache.key(parent: "sha256:aaa", instruction: "RUN make test"))
        #expect(base != BuildCache.key(parent: "sha256:aaa", instruction: "RUN make", inputs: ["files"]))
    }

    @Test func fingerprintFollowsContentAndMode() throws {
        try TemporaryDirectory.with("macker-fingerprint") { work in
            let tree = work.appendingPathComponent("tree", isDirectory: true)
            let file = tree.appendingPathComponent("app.txt")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try "one\n".write(to: file, atomically: true, encoding: .utf8)

            let first = try BuildCache.fingerprint(of: tree)
            let repeated = try BuildCache.fingerprint(of: tree)
            #expect(first == repeated)

            try "two\n".write(to: file, atomically: true, encoding: .utf8)
            let afterEdit = try BuildCache.fingerprint(of: tree)
            #expect(afterEdit != first)

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            let afterChmod = try BuildCache.fingerprint(of: tree)
            #expect(afterChmod != afterEdit)
        }
    }

    @Test func cacheIndexSurvivesReloadAndForget() throws {
        try TemporaryDirectory.with("macker-cache") { store in
            var cache = BuildCache(store: store)
            cache.record(key: "one", reference: "sha256:aaa")
            cache.record(key: "two", reference: "sha256:bbb")
            #expect(BuildCache(store: store).reference(for: "one") == "sha256:aaa")

            cache.forget(references: ["sha256:aaa"])
            #expect(BuildCache(store: store).reference(for: "one") == nil)
            #expect(BuildCache(store: store).references == ["sha256:bbb"])
        }
    }

    @Test func copyParsesSourcesFlagsAndBothForms() throws {
        let shell = try EngineManager.parseCopy(
            DockerfileInstruction(name: "COPY", arguments: "a b /dest/", flags: DockerfileFlags(["from": "builder"]))
        )
        #expect(shell.sources == ["a", "b"])
        #expect(shell.destination == "/dest/")
        #expect(shell.from == "builder")
        #expect(!shell.isAdd)

        let json = try EngineManager.parseCopy(
            DockerfileInstruction(name: "ADD", arguments: "[\"src dir\", \"/dest\"]")
        )
        #expect(json.sources == ["src dir"])
        #expect(json.isAdd)

        #expect(throws: EngineError.self) {
            try EngineManager.parseCopy(DockerfileInstruction(name: "COPY", arguments: "only-one"))
        }
        #expect(throws: EngineError.self) {
            try EngineManager.parseCopy(
                DockerfileInstruction(name: "COPY", arguments: "a /b", flags: DockerfileFlags(["link": ""]))
            )
        }
    }

    @Test func copyOwnershipDefaultsToRootAndTakesNumericChown() throws {
        #expect(try EngineManager.copyOwnership(DockerfileInstruction(name: "COPY", arguments: "a /b")) == .root)
        #expect(
            try EngineManager.copyOwnership(
                DockerfileInstruction(name: "COPY", arguments: "a /b", flags: DockerfileFlags(["chown": "1000:1001"]))
            ) == .numeric(uid: 1000, gid: 1001)
        )
        #expect(
            try EngineManager.copyOwnership(
                DockerfileInstruction(name: "COPY", arguments: "a /b", flags: DockerfileFlags(["chown": "1000"]))
            ) == .numeric(uid: 1000, gid: 1000)
        )
        #expect(throws: EngineError.self) {
            try EngineManager.copyOwnership(
                DockerfileInstruction(name: "COPY", arguments: "a /b", flags: DockerfileFlags(["chown": "app:app"]))
            )
        }
    }

    @Test func copySourcesResolveLiteralsAndGlobs() throws {
        try TemporaryDirectory.with("macker-copy-sources") { root in
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try "a\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
            try "b\n".write(to: root.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
            try "c\n".write(to: root.appendingPathComponent("src/c.md"), atomically: true, encoding: .utf8)

            #expect(try EngineManager.matchSources(root: root, pattern: "src/a.txt", instruction: "COPY") == ["/src/a.txt"])
            #expect(try EngineManager.matchSources(root: root, pattern: "./src", instruction: "COPY") == ["/src"])
            #expect(
                try EngineManager.matchSources(root: root, pattern: "src/*.txt", instruction: "COPY")
                    == ["/src/a.txt", "/src/b.txt"]
            )
            #expect(throws: EngineError.self) {
                try EngineManager.matchSources(root: root, pattern: "missing.txt", instruction: "COPY")
            }
            #expect(throws: EngineError.self) {
                try EngineManager.matchSources(root: root, pattern: "src/*.rs", instruction: "COPY")
            }
            #expect(throws: EngineError.self) {
                try EngineManager.matchSources(root: root, pattern: "../escape", instruction: "COPY")
            }
        }
    }

    @Test func destinationSpellingDecidesFileOrDirectory() {
        #expect(EngineManager.spelledAsDirectory("/dest/"))
        #expect(EngineManager.spelledAsDirectory("."))
        #expect(EngineManager.spelledAsDirectory("./"))
        #expect(EngineManager.spelledAsDirectory("out/."))
        #expect(EngineManager.spelledAsDirectory(".."))
        #expect(!EngineManager.spelledAsDirectory("/etc"))
        #expect(!EngineManager.spelledAsDirectory("app.txt"))
    }

    @Test func workdirLayerHoldsTheDirectoryChain() throws {
        try TemporaryDirectory.with("macker-workdir-layer") { work in
            let staged = try EngineManager.stageDirectory("/usr/src/app", work: work)
            #expect(staged != nil)
            #expect(
                FileManager.default.fileExists(
                    atPath: staged!.appendingPathComponent("usr/src/app").path
                )
            )
            #expect(try EngineManager.stageDirectory("/", work: work) == nil)
        }
    }

    @Test func runHistoryMatchesTheShellUsed() {
        let shellForm = DockerfileInstruction(name: "RUN", arguments: "echo hi")
        #expect(EngineManager.runCreatedBy(shellForm, shell: ["/bin/sh", "-c"]) == "/bin/sh -c echo hi")
        #expect(EngineManager.runCreatedBy(shellForm, shell: ["/bin/bash", "-lc"]) == "/bin/bash -lc echo hi")

        let execForm = DockerfileInstruction(name: "RUN", arguments: "[\"echo\",\"hi\"]")
        #expect(EngineManager.runCreatedBy(execForm, shell: ["/bin/sh", "-c"]) == "[\"echo\",\"hi\"]")
    }

    @Test func layerTarRecordsRootOwnership() throws {
        try TemporaryDirectory.with("macker-layer-owner") { work in
            let tree = work.appendingPathComponent("tree", isDirectory: true)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try "hi\n".write(to: tree.appendingPathComponent("hi.txt"), atomically: true, encoding: .utf8)

            let archive = work.appendingPathComponent("layer.tar")
            try TarArchive.createContents(of: tree, into: archive, ownership: .root)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-tvf", archive.path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let listing = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            process.waitUntilExit()
            #expect(listing.contains("root"))
        }
    }

    @Test func buildSpecReadsNetworkHostsAndMemory() {
        let request = HTTPRequest(
            method: "POST",
            path: "/build",
            query: [
                "networkmode": "none",
                "extrahosts": "db.local:10.1.2.3, host.docker.internal:host-gateway",
                "memory": "134217728",
            ]
        )
        let spec = Router.buildSpec(from: request)
        #expect(spec.networkMode == "none")
        #expect(spec.extraHosts == ["db.local:10.1.2.3", "host.docker.internal:host-gateway"])
        #expect(spec.memory == 134_217_728)
        #expect(throws: EngineError.self) {
            try EngineManager.validateBuildSpec(EngineBuildSpec(networkMode: "container:abc"))
        }
        #expect(throws: EngineError.self) {
            try EngineManager.validateBuildSpec(EngineBuildSpec(extraHosts: ["badhost"]))
        }
    }

    @Test func buildCacheIDMatchesDigestPrefixes() {
        let digest = "sha256:abcdef0123456789"
        #expect(EngineManager.buildCacheIDMatches(digest, ids: ["sha256:abcdef"]))
        #expect(EngineManager.buildCacheIDMatches(digest, ids: ["abcdef"]))
        #expect(!EngineManager.buildCacheIDMatches(digest, ids: ["ffff"]))
        #expect(!EngineManager.buildCacheIDMatches(digest, ids: ["sha256:"]))
        #expect(EngineManager.unsupportedBuildNetwork(" container:abc ") == "container:abc")
        #expect(EngineManager.unsupportedBuildNetwork("bridge") == nil)
    }
}
