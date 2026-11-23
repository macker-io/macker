import Foundation
import Testing
@testable import ContainerEngine

struct FilesystemCommandTests {
    @Test func diffDetectsAddModifyDelete() {
        let baseline: [String: FSEntry] = [
            "/etc/hosts": FSEntry(kind: .file, size: 10, mode: 0o644, mtime: 1),
            "/bin/sh": FSEntry(kind: .file, size: 100, mode: 0o755, mtime: 1),
            "/tmp": FSEntry(kind: .directory, size: 0, mode: 0o755, mtime: 1),
        ]
        let current: [String: FSEntry] = [
            "/etc/hosts": FSEntry(kind: .file, size: 12, mode: 0o644, mtime: 2),
            "/tmp": FSEntry(kind: .directory, size: 0, mode: 0o755, mtime: 99),
            "/hello": FSEntry(kind: .file, size: 3, mode: 0o644, mtime: 3),
        ]
        let changes = FSInventory.diff(baseline: baseline, current: current)
        #expect(changes == [
            EngineFSChange(path: "/bin/sh", kind: .delete),
            EngineFSChange(path: "/etc/hosts", kind: .modify),
            EngineFSChange(path: "/hello", kind: .add),
        ])
    }

    @Test func liveDiffChecksBytesBeyondFirstChunkWithoutRelyingOnMtime() async throws {
        try await withEngine { engine in
            let prefix = String(repeating: "a", count: 1 << 20)
            try await RouterTestSupport.importTagged(engine, repo: "live-diff", hello: prefix + "A")
            let id = try await engine.createContainer(.init(image: "live-diff")).id
            let container = try await engine.inspectContainer(id).container
            try await TemporaryDirectory.with("macker-live-diff") { root in
                let file = root.appendingPathComponent("hello.txt")
                try (prefix + "A").write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                #expect(try await engine.extractedChanges(container, root: root).isEmpty)
                try (prefix + "B").write(to: file, atomically: false, encoding: .utf8)
                #expect(try await engine.extractedChanges(container, root: root) == [.init(path: "/hello.txt", kind: .modify)])
            }
        }
    }

    @Test func directoryMtimeDoesNotCountAsModify() {
        let baseline = ["/var": FSEntry(kind: .directory, size: 0, mode: 0o755, mtime: 1)]
        let current = ["/var": FSEntry(kind: .directory, size: 0, mode: 0o755, mtime: 50)]
        #expect(FSInventory.diff(baseline: baseline, current: current).isEmpty)
    }

    @Test func whiteoutPathAndTopmostDeletes() {
        #expect(FSInventory.whiteoutPath(for: "/usr/bin/foo") == "/usr/bin/.wh.foo")
        #expect(FSInventory.whiteoutPath(for: "/foo") == "/.wh.foo")
        let top = FSInventory.topmostDeletes(["/usr", "/usr/bin", "/usr/bin/foo", "/etc/hosts"])
        #expect(Set(top) == ["/usr", "/etc/hosts"])
    }

    @Test func excludesVolumeMountChildren() {
        #expect(FSInventory.isExcluded("/data/file", mounts: ["/data"]))
        #expect(!FSInventory.isExcluded("/data", mounts: ["/data"]))
        #expect(!FSInventory.isExcluded("/data2", mounts: ["/data"]))
        #expect(!FSInventory.isExcluded("/etc/hosts", mounts: ["/data"]))
    }

    @Test func containerPathRequiresDirectoryBoundary() {
        let root = URL(filePath: "/tmp/foo")
        #expect(FSInventory.containerPath(for: URL(filePath: "/tmp/foo/bar"), root: root) == "/bar")
        #expect(FSInventory.containerPath(for: URL(filePath: "/tmp/foo-bar"), root: root) == nil)
        #expect(FSInventory.containerPath(for: root, root: root) == nil)
    }

    @Test func packLayerWritesWhiteoutsAndCopiesAdds() throws {
        try TemporaryDirectory.with("macker-layer-test") { work in
            let root = work.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("etc"), withIntermediateDirectories: true)
            try "hi\n".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
            try "old\n".write(to: root.appendingPathComponent("etc/hosts"), atomically: true, encoding: .utf8)

            let staged = work.appendingPathComponent("layer")
            try FSInventory.packLayer(
                from: root,
                changes: [
                    EngineFSChange(path: "/hello.txt", kind: .add),
                    EngineFSChange(path: "/bin/sh", kind: .delete),
                ],
                into: staged
            )
            let hello = try String(contentsOf: staged.appendingPathComponent("hello.txt"), encoding: .utf8)
            #expect(hello == "hi\n")
            #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("bin/.wh.sh").path))
        }
    }

    @Test func packLayerStagesDirectoriesWithoutCopyingChildren() throws {
        try TemporaryDirectory.with("macker-layer-dir") { work in
            let root = work.appendingPathComponent("root")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("app/child"),
                withIntermediateDirectories: true
            )
            try "keep\n".write(
                to: root.appendingPathComponent("app/child/file.txt"),
                atomically: true,
                encoding: .utf8
            )
            let staged = work.appendingPathComponent("layer")
            try FSInventory.packLayer(
                from: root,
                changes: [EngineFSChange(path: "/app", kind: .modify)],
                into: staged
            )
            #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("app").path))
            #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("app/child").path))
        }
    }

    @Test func packLayerKeepsAddedChildrenWhenDirectoryAlsoChanges() throws {
        try TemporaryDirectory.with("macker-layer-dir-child") { work in
            let root = work.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
            try "new\n".write(to: root.appendingPathComponent("app/file.txt"), atomically: true, encoding: .utf8)
            let staged = work.appendingPathComponent("layer")
            try FSInventory.packLayer(
                from: root,
                changes: [
                    EngineFSChange(path: "/app/file.txt", kind: .add),
                    EngineFSChange(path: "/app", kind: .modify),
                ],
                into: staged
            )
            let text = try String(contentsOf: staged.appendingPathComponent("app/file.txt"), encoding: .utf8)
            #expect(text == "new\n")
        }
    }

    /// Image rootfs trees are full of absolute symlinks (`/bin/cat` → `/bin/busybox`)
    /// that dangle on the host. Losing them makes a commit whiteout half of `/bin`.
    @Test func walkKeepsDanglingAbsoluteSymlinks() throws {
        try TemporaryDirectory.with("macker-walk-links") { work in
            let root = work.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try "binary\n".write(to: root.appendingPathComponent("bin/busybox"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent("bin/cat").path,
                withDestinationPath: "/bin/busybox"
            )
            let entries = FSInventory.walkDirectory(root)
            #expect(entries["/bin/busybox"]?.kind == .file)
            #expect(entries["/bin/cat"]?.kind == .symlink)
            #expect(FSInventory.diff(baseline: entries, current: entries).isEmpty)
        }
    }

    @Test func dockerfileChangesMergeIntoConfig() throws {
        var config = CommitRuntimeConfig()
        try CommitConfig.applyInstructions(
            [
                "ENV FOO=bar",
                "ENV BAZ qux",
                "LABEL a=b",
                "CMD [\"echo\",\"hi\"]",
                "EXPOSE 80",
                "USER nobody",
                "WORKDIR /app",
            ],
            to: &config
        )
        #expect(config.Env == ["FOO=bar", "BAZ=qux"])
        #expect(config.Labels == ["a": "b"])
        #expect(config.Cmd == ["echo", "hi"])
        #expect(config.ExposedPorts?["80/tcp"] != nil)
        #expect(config.User == "nobody")
        #expect(config.WorkingDir == "/app")
    }

    @Test func envOverlayReplacesMatchingKeys() {
        #expect(CommitConfig.mergeEnv(["PATH=/bin", "FOO=1"], ["FOO=2", "BAR=3"]) == ["PATH=/bin", "FOO=2", "BAR=3"])
    }

    @Test func commitJSONUsesOCISnakeCaseKeys() throws {
        let rootfs = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CommitRootFS(type: "layers", diffIDs: ["sha256:abc"]))
        ) as? [String: Any]
        #expect(rootfs?["diff_ids"] as? [String] == ["sha256:abc"])

        let history = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                CommitHistory(created: "now", createdBy: "COMMIT", author: nil, comment: nil, emptyLayer: true)
            )
        ) as? [String: Any]
        #expect(history?["created_by"] as? String == "COMMIT")
        #expect(history?["empty_layer"] as? Bool == true)
    }

    @Test func digestReferencesAreHiddenFromRepoTags() {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        #expect(EngineManager.isDigestReference(digest))
        #expect(!EngineManager.isDigestReference("sha256:stable"))
        #expect(!EngineManager.isDigestReference("docker.io/library/alpine:latest"))
        #expect(EngineManager.uniqueDisplayTags([digest, "alpine:latest"]) == ["alpine:latest"])
        #expect(EngineManager.uniqueDisplayTags([digest]).isEmpty)
        #expect(EngineManager.uniqueDisplayTags(["sha256:stable"]) == ["sha256:stable"])
    }
}
