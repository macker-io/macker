import ContainerizationOCI
import Foundation

extension EngineManager {
    /// Turns a rootfs tar (request body or HTTP URL) into a single-layer image.
    public func importImage(spec: EngineImportSpec, archive: URL? = nil) -> AsyncThrowingStream<ImagePullEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Importing", id: nil))
                    let digest = try await self.writeImportedImage(spec: spec, archive: archive)
                    continuation.yield(.status(digest, id: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func writeImportedImage(spec: EngineImportSpec, archive: URL?) async throws -> String {
        var runtime = CommitRuntimeConfig()
        try CommitConfig.applyInstructions(spec.changes, to: &runtime)
        let platform = try Self.buildPlatform(spec.platform)

        return try await withScratch("macker-import") { work in
            let tar = try await self.resolveImportArchive(spec.source, archive: archive, work: work)
            let root = work.appendingPathComponent("root", isDirectory: true)
            try TarArchive.extract(tar, to: root)

            let createdAt = Date()
            let ingested = try await self.ingestImage(
                config: CommitImageFile(
                    created: ISO8601.string(from: createdAt),
                    author: nil,
                    architecture: platform.architecture,
                    os: platform.os,
                    osVersion: nil,
                    osFeatures: nil,
                    variant: platform.variant,
                    config: runtime,
                    rootfs: CommitRootFS(type: "layers", diffIDs: []),
                    history: []
                ),
                parentLayers: [],
                platform: platform,
                layer: try self.stageLayer(from: root, work: work),
                history: CommitHistory(
                    created: ISO8601.string(from: createdAt),
                    createdBy: "",
                    author: nil,
                    comment: spec.message.isEmpty ? nil : spec.message,
                    emptyLayer: nil
                )
            )

            let (image, reference) = try await self.registerIngested(ingested, repo: spec.repo, tag: spec.tag)
            await self.publishImage(action: "import", digest: image.digest, name: reference)
            return image.digest
        }
    }

    private func resolveImportArchive(_ source: String, archive: URL?, work: URL) async throws -> URL {
        if source == "-" {
            guard let archive else {
                throw EngineError.loadFailed("a tar archive is required")
            }
            return try Self.requireArchive(archive)
        }
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw EngineError.invalidArgument("invalid import source \(source)")
        }
        return try await Self.download(url, to: work.appendingPathComponent("src.tar"))
    }

    private static func requireArchive(_ url: URL) throws -> URL {
        guard (try? TarArchive.size(of: url)) ?? 0 > 0 else {
            throw EngineError.loadFailed("empty archive")
        }
        return url
    }

    private static func download(_ url: URL, to destination: URL) async throws -> URL {
        let (temp, response) = try await URLSession.shared.download(from: url)
        do {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw EngineError.loadFailed("failed to fetch \(url.absoluteString): HTTP \(http.statusCode)")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
            return try requireArchive(destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
