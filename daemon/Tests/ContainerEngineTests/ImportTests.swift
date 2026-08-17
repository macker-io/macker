import Foundation
import Testing
@testable import ContainerEngine

struct ImportTests {
    @Test func importCreatesTaggedImageFromTar() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-import-test") { work in
                let digest = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(
                            source: "-",
                            repo: "imported",
                            tag: "latest",
                            message: "from test",
                            changes: [#"CMD ["cat", "/hello.txt"]"#, "ENV FOO=bar"]
                        ),
                        archive: try pack(hello: "hello\n", in: work)
                    )
                )

                let inspect = try await engine.inspectImage(name: "imported:latest")
                #expect(inspect.id == digest)
                #expect(inspect.cmd == ["cat", "/hello.txt"])
                #expect(inspect.env.contains("FOO=bar"))
                #expect(inspect.size > 0)
                let history = try await engine.imageHistory(name: "imported:latest")
                #expect(history.contains { $0.comment == "from test" })
            }
        }
    }

    @Test func importAcceptsGzipTar() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-import-gz") { work in
                let tar = try pack(hello: "gz\n", in: work, file: "file")
                let gzip = work.appendingPathComponent("rootfs.tar.gz")
                try TarArchive.gzip(tar, to: gzip)
                let digest = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-", repo: "gzimg", tag: "v1"),
                        archive: gzip
                    )
                )
                #expect(try await engine.inspectImage(name: "gzimg:v1").id == digest)
            }
        }
    }

    @Test func importWithoutRepoIsDangling() async throws {
        try await withEngine { engine in
            try await TemporaryDirectory.with("macker-import-dangling") { work in
                let digest = try await collectDigest(
                    await engine.importImage(
                        spec: EngineImportSpec(source: "-"),
                        archive: try pack(hello: "x", in: work, file: "x")
                    )
                )
                #expect(try await engine.inspectImage(name: digest).repoTags.isEmpty)
            }
        }
    }

    @Test func importRejectsEmptyArchiveAndBadChanges() async throws {
        try await withEngine { engine in
            await #expect(throws: EngineError.self) {
                for try await _ in await engine.importImage(spec: EngineImportSpec(source: "-")) {}
            }
            _ = try await TemporaryDirectory.with("macker-import-bad") { work in
                await #expect(throws: EngineError.self) {
                    for try await _ in await engine.importImage(
                        spec: EngineImportSpec(source: "-", changes: ["RUN echo no"]),
                        archive: try pack(hello: "x", in: work, file: "x")
                    ) {}
                }
            }
        }
    }
}

private func pack(hello: String, in work: URL, file: String = "hello.txt") throws -> URL {
    let root = work.appendingPathComponent("root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try hello.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
    let tar = work.appendingPathComponent("rootfs.tar")
    try TarArchive.createContents(of: root, into: tar)
    return tar
}

private func collectDigest(_ stream: AsyncThrowingStream<ImagePullEvent, Error>) async throws -> String {
    var digest: String?
    for try await event in stream {
        if case .status(let text, _) = event, text.hasPrefix("sha256:") {
            digest = text
        }
    }
    guard let digest else {
        throw EngineError.loadFailed("import did not report a digest")
    }
    return digest
}

private func withEngine(_ body: (EngineManager) async throws -> Void) async throws {
    try await TemporaryDirectory.with("macker-import") { dir in
        try await body(try EngineManager(storePath: dir))
    }
}
