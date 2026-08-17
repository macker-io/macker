import Containerization
import ContainerizationOCI
import Foundation

/// A staged, compressed layer waiting to be ingested into the content store.
struct ImageLayerBlob: Sendable {
    var gzip: URL
    var digest: String
    var size: Int64
    var diffID: String
    var uncompressedSize: Int64

    var descriptor: Descriptor {
        Descriptor(
            mediaType: MediaTypes.imageLayerGzip,
            digest: digest,
            size: size,
            annotations: [ImageLayerSize.uncompressedAnnotation: String(uncompressedSize)]
        )
    }
}

/// What an ingest wrote: the index descriptor plus the config and layer list that
/// describe the new image, so a builder can keep stacking without re-reading the store.
struct IngestedImage: Sendable {
    var descriptor: Descriptor
    var config: CommitImageFile
    var layers: [Descriptor]
}

extension EngineManager {
    /// Packs `changes` out of `root` into a gzip layer under `work`.
    /// Returns `nil` when nothing changed, which becomes an empty-layer history entry.
    func stageLayer(
        root: URL,
        changes: [EngineFSChange],
        work: URL,
        ownership: TarArchive.Ownership = .root
    ) throws -> ImageLayerBlob? {
        guard !changes.isEmpty else { return nil }
        let staged = work.appendingPathComponent("layer", isDirectory: true)
        try FSInventory.packLayer(from: root, changes: changes, into: staged)
        return try stageLayer(from: staged, work: work, ownership: ownership)
    }

    /// Packs an already-staged tree (a whole layer, e.g. the files a `COPY` adds).
    func stageLayer(from staged: URL, work: URL, ownership: TarArchive.Ownership = .root) throws -> ImageLayerBlob {
        let tar = work.appendingPathComponent("layer.tar")
        try TarArchive.createContents(of: staged, into: tar, ownership: ownership)
        let gzip = work.appendingPathComponent("layer.tar.gz")
        try TarArchive.gzip(tar, to: gzip)
        return ImageLayerBlob(
            gzip: gzip,
            digest: try TarArchive.sha256(of: gzip),
            size: try TarArchive.size(of: gzip),
            diffID: try TarArchive.sha256(of: tar),
            uncompressedSize: try TarArchive.size(of: tar)
        )
    }

    /// Writes config, manifest and index for `parentLayers` plus an optional new layer.
    /// Shared by `commit` and the Dockerfile builder.
    @discardableResult
    func ingestImage(
        config: CommitImageFile,
        parentLayers: [Descriptor],
        platform: Platform,
        layer: ImageLayerBlob?,
        history: CommitHistory
    ) async throws -> IngestedImage {
        var imageFile = config
        var entry = history
        var layers = parentLayers
        if let layer {
            imageFile.rootfs.diffIDs.append(layer.diffID)
            layers.append(layer.descriptor)
            entry.emptyLayer = nil
        } else {
            entry.emptyLayer = true
        }
        imageFile.history = (imageFile.history ?? []) + [entry]

        let contentStore = try LocalContentStore(path: imageStore.path.appendingPathComponent("content"))
        let box = DescriptorBox()
        let encoded = imageFile
        let manifestLayers = layers
        try await contentStore.ingest { dir in
            let writer = try ContentWriter(for: dir)
            if let layer {
                _ = try writer.create(from: layer.gzip)
            }
            let configResult = try writer.create(from: encoded)
            let manifestResult = try writer.create(
                from: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: configResult.digest.digestString,
                        size: configResult.size
                    ),
                    layers: manifestLayers
                )
            )
            let indexResult = try writer.create(
                from: Index(
                    manifests: [
                        Descriptor(
                            mediaType: MediaTypes.imageManifest,
                            digest: manifestResult.digest.digestString,
                            size: manifestResult.size,
                            platform: platform
                        )
                    ]
                )
            )
            box.set(
                Descriptor(
                    mediaType: MediaTypes.index,
                    digest: indexResult.digest.digestString,
                    size: indexResult.size
                )
            )
        }
        guard let descriptor = box.get() else {
            throw EngineError.exportFailed("failed to write image manifest")
        }
        return IngestedImage(descriptor: descriptor, config: imageFile, layers: layers)
    }

    /// Registers a freshly ingested image under its digest, so it is resolvable but
    /// untagged (`images -a` shows it as dangling).
    func adoptImage(_ descriptor: Descriptor) async throws -> Containerization.Image {
        if let existing = try? await imageStore.get(reference: descriptor.digest) {
            return existing
        }
        return try await imageStore.create(description: .init(reference: descriptor.digest, descriptor: descriptor))
    }
}

/// `LocalContentStore.ingest` hands work to a non-isolated closure; this carries the result out.
final class DescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Descriptor?

    func set(_ descriptor: Descriptor) {
        lock.lock()
        value = descriptor
        lock.unlock()
    }

    func get() -> Descriptor? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
