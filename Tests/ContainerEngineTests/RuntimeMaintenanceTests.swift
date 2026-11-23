import Darwin
import Foundation
import Testing
@testable import ContainerEngine

struct RuntimeMaintenanceTests {
    @Test func inspectionDoesNotCreateMissingStore() throws {
        try TemporaryDirectory.with("macker-runtime-probe") { work in
            let store = work.appendingPathComponent("missing")
            _ = RuntimeAssets.inspectFiles(storePath: store)
            #expect(!FileManager.default.fileExists(atPath: store.path))
        }
    }

    @Test func fetchRefusesOwnedStoreBeforeOpeningIt() async throws {
        try await TemporaryDirectory.with("macker-runtime-lock") { store in
            let lock = try DaemonInstanceLock.acquire(storeDirectory: store)
            defer { lock.release() }
            await #expect(throws: EngineError.self) {
                _ = try await RuntimeAssets.fetch(storePath: store)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.path) == ["daemon.lock"])
        }
    }

    @Test func stagingDoesNotRecoverActiveContainerRecords() async throws {
        try await TemporaryDirectory.with("macker-runtime-stage") { store in
            let engine = try EngineManager(storePath: store)
            try await RouterTestSupport.importTagged(engine, repo: "fixture")
            let id = try await engine.createContainer(.init(image: "fixture", autoRemove: true)).id
            var active = try await engine.inspectContainer(id).container
            active.state = "running"
            await engine.saveContainer(active)
            let record = store.appendingPathComponent("containers/\(id).json")
            let before = try Data(contentsOf: record)

            // Supply the two local artifacts so no download or VM is required.
            try FileManager.default.createDirectory(at: store.appendingPathComponent("runtime"), withIntermediateDirectories: true)
            try Data([1]).write(to: store.appendingPathComponent("runtime/vmlinux"))
            try Data([2]).write(to: store.appendingPathComponent("initfs.ext4"))
            let output = store.appendingPathComponent("staged")
            _ = try await RuntimeAssets.fetch(storePath: store, output: output)
            #expect(try Data(contentsOf: output.appendingPathComponent("vmlinux")) == Data([1]))
            #expect(try Data(contentsOf: output.appendingPathComponent("initfs.ext4")) == Data([2]))
            #expect(try Data(contentsOf: record) == before)
        }
    }

    @Test func stageRejectsDirectoryDestinationWithoutDeletingIt() throws {
        try TemporaryDirectory.with("macker-runtime-dir-dest") { work in
            let kernel = work.appendingPathComponent("src-vmlinux")
            let initfs = work.appendingPathComponent("src-initfs.ext4")
            try Data([1]).write(to: kernel)
            try Data([2]).write(to: initfs)

            let output = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let blocked = output.appendingPathComponent("vmlinux", isDirectory: true)
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            let marker = blocked.appendingPathComponent("keep")
            try Data([9]).write(to: marker)

            let status = RuntimeStatus(
                kernelPath: kernel.path,
                initfsPath: initfs.path,
                vminitReference: "test",
                vminitPresent: false
            )
            #expect(throws: EngineError.self) {
                try RuntimeAssets.stage(status: status, to: output)
            }
            #expect(try Data(contentsOf: marker) == Data([9]))
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: blocked.path, isDirectory: &isDir) && isDir.boolValue)
            #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("initfs.ext4").path))
        }
    }

    @Test func stageRejectsFIFOSource() throws {
        try TemporaryDirectory.with("macker-runtime-fifo-src") { work in
            let fifo = work.appendingPathComponent("vmlinux")
            let initfs = work.appendingPathComponent("src-initfs.ext4")
            #expect(mkfifo(fifo.path, 0o644) == 0)
            try Data([2]).write(to: initfs)

            let output = work.appendingPathComponent("out", isDirectory: true)
            let status = RuntimeStatus(
                kernelPath: fifo.path,
                initfsPath: initfs.path,
                vminitReference: "test",
                vminitPresent: false
            )
            #expect(throws: EngineError.self) {
                try RuntimeAssets.stage(status: status, to: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func stageSameSourceDestinationIsNoOpIncludingSymlinkParent() throws {
        try TemporaryDirectory.with("macker-runtime-same-path") { work in
            let kernel = work.appendingPathComponent("vmlinux")
            let initfs = work.appendingPathComponent("initfs.ext4")
            try Data([1]).write(to: kernel)
            try Data([2]).write(to: initfs)

            var kernelBefore = stat(), initfsBefore = stat()
            #expect(stat(kernel.path, &kernelBefore) == 0)
            #expect(stat(initfs.path, &initfsBefore) == 0)

            let alias = work.appendingPathComponent("alias-parent")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: work)

            let status = RuntimeStatus(
                kernelPath: alias.appendingPathComponent("vmlinux").path,
                initfsPath: alias.appendingPathComponent("initfs.ext4").path,
                vminitReference: "test",
                vminitPresent: false
            )
            try RuntimeAssets.stage(status: status, to: work)
            #expect(try Data(contentsOf: kernel) == Data([1]))
            #expect(try Data(contentsOf: initfs) == Data([2]))
            var kernelAfter = stat(), initfsAfter = stat()
            #expect(stat(kernel.path, &kernelAfter) == 0)
            #expect(stat(initfs.path, &initfsAfter) == 0)
            #expect(kernelBefore.st_dev == kernelAfter.st_dev && kernelBefore.st_ino == kernelAfter.st_ino)
            #expect(initfsBefore.st_dev == initfsAfter.st_dev && initfsBefore.st_ino == initfsAfter.st_ino)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: work.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }
}
