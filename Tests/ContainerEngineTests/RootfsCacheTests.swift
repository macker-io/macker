import Foundation
import Testing
@testable import ContainerEngine

struct RootfsCacheTests {
    @Test func cacheKeyReplacesDigestColon() {
        #expect(EngineManager.unpackedCacheKey("sha256:abc") == "sha256-abc")
    }

    @Test func cloneOrCopyMakesAnIndependentFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("src.bin")
        let dest = dir.appendingPathComponent("dst.bin")
        try Data("hello".utf8).write(to: source)
        try EngineManager.cloneOrCopy(from: source, to: dest)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "hello")
        try Data("world".utf8).write(to: source)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "hello")
    }
}
