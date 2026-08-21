import Foundation
@testable import ContainerEngine

enum EngineTestSupport {
    static func withEngine(
        _ prefix: String = "macker-test",
        _ body: (EngineManager) async throws -> Void
    ) async throws {
        try await TemporaryDirectory.with(prefix) { dir in
            try await body(try EngineManager(storePath: dir))
        }
    }

    static func pack(hello: String, in work: URL, file: String = "hello.txt") throws -> URL {
        let root = work.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try hello.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let tar = work.appendingPathComponent("rootfs.tar")
        try TarArchive.createContents(of: root, into: tar)
        return tar
    }

    static func collectDigest(_ stream: AsyncThrowingStream<ImagePullEvent, Error>) async throws -> String {
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
}

func withEngine(
    _ prefix: String = "macker-test",
    _ body: (EngineManager) async throws -> Void
) async throws {
    try await EngineTestSupport.withEngine(prefix, body)
}

func pack(hello: String, in work: URL, file: String = "hello.txt") throws -> URL {
    try EngineTestSupport.pack(hello: hello, in: work, file: file)
}

func collectDigest(_ stream: AsyncThrowingStream<ImagePullEvent, Error>) async throws -> String {
    try await EngineTestSupport.collectDigest(stream)
}
