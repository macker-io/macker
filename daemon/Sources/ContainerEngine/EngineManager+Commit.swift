import Containerization
import ContainerizationOCI
import Foundation

extension EngineManager {
    public func commitContainer(_ idOrName: String, spec: EngineCommitSpec) async throws -> String {
        var preview = CommitRuntimeConfig()
        try CommitConfig.applyInstructions(spec.changes, to: &preview)

        let container = try requireFilesystem(idOrName)
        return try await withExtractedRootfs(container) { root in
            let current = FSInventory.walkDirectory(root, excluding: self.mountDestinations(container))
            let baseline = try await self.loadBaseline(container)
            return try await self.writeCommittedImage(
                container: container,
                spec: spec,
                root: root,
                changes: FSInventory.diff(baseline: baseline, current: current)
            )
        }
    }

    private func writeCommittedImage(
        container: EngineContainer,
        spec: EngineCommitSpec,
        root: URL,
        changes: [EngineFSChange]
    ) async throws -> String {
        let parent = try await resolveImage(container.image)
        let platform = await Self.preferredPlatform(for: parent)
        let manifest = try await parent.manifest(for: platform)
        let configBlob = try await parent.getContent(digest: manifest.config.digest)
        var imageFile: CommitImageFile = try configBlob.decode()
        var runtime = imageFile.config ?? CommitRuntimeConfig()
        CommitConfig.applyContainer(container, to: &runtime)
        if let overlay = spec.config {
            CommitConfig.applySpec(overlay, to: &runtime)
        }
        try CommitConfig.applyInstructions(spec.changes, to: &runtime)
        imageFile.config = runtime

        let createdAt = Date()
        imageFile.created = ISO8601.string(from: createdAt)
        if !spec.author.isEmpty {
            imageFile.author = spec.author
        }

        let descriptor = try await withScratch("macker-layer") { work in
            let staged = work.appendingPathComponent("layer", isDirectory: true)
            try FSInventory.packLayer(from: root, changes: changes, into: staged)
            let tar = work.appendingPathComponent("layer.tar")
            try TarArchive.createContents(of: staged, into: tar)
            let gzip = work.appendingPathComponent("layer.tar.gz")
            try TarArchive.gzip(tar, to: gzip)
            return try await self.ingestCommittedImage(
                imageFile: imageFile,
                parentLayers: manifest.layers,
                platform: platform,
                gzip: gzip,
                diffID: try TarArchive.sha256(of: tar),
                uncompressedSize: try TarArchive.size(of: tar),
                spec: spec,
                createdAt: createdAt
            )
        }

        let reference: String
        if let repo = spec.repo, !repo.isEmpty {
            reference = try Self.normalizedReference(name: repo, tag: spec.tag)
        } else {
            reference = descriptor.digest
        }
        let image = try await imageStore.create(description: .init(reference: reference, descriptor: descriptor))
        await publish(
            EngineEvent(
                type: "container",
                action: "commit",
                actorID: container.id,
                attributes: ["image": image.digest, "name": container.name]
            )
        )
        await publish(
            EngineEvent(
                type: "image",
                action: spec.repo == nil ? "commit" : "tag",
                actorID: image.digest,
                attributes: ["name": reference]
            )
        )
        return image.digest
    }

    private func ingestCommittedImage(
        imageFile: CommitImageFile,
        parentLayers: [Descriptor],
        platform: Platform,
        gzip: URL,
        diffID: String,
        uncompressedSize: Int64,
        spec: EngineCommitSpec,
        createdAt: Date
    ) async throws -> Descriptor {
        var imageFile = imageFile
        imageFile.rootfs.diffIDs.append(diffID)
        imageFile.history = (imageFile.history ?? []) + [
            CommitHistory(
                created: ISO8601.string(from: createdAt),
                createdBy: "#(nop) COMMIT",
                author: spec.author.isEmpty ? imageFile.author : spec.author,
                comment: spec.comment.isEmpty ? nil : spec.comment,
                emptyLayer: nil
            )
        ]

        let contentStore = try LocalContentStore(path: imageStore.path.appendingPathComponent("content"))
        let box = DescriptorBox()
        let encoded = imageFile
        try await contentStore.ingest { dir in
            let writer = try ContentWriter(for: dir)
            let layerResult = try writer.create(from: gzip)
            let configResult = try writer.create(from: encoded)
            let manifestResult = try writer.create(
                from: Manifest(
                    config: Descriptor(
                        mediaType: MediaTypes.imageConfig,
                        digest: configResult.digest.digestString,
                        size: configResult.size
                    ),
                    layers: parentLayers + [
                        Descriptor(
                            mediaType: MediaTypes.imageLayerGzip,
                            digest: layerResult.digest.digestString,
                            size: layerResult.size,
                            annotations: [ImageLayerSize.uncompressedAnnotation: String(uncompressedSize)]
                        )
                    ]
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
            throw EngineError.exportFailed("failed to write committed image")
        }
        return descriptor
    }
}

private final class DescriptorBox: @unchecked Sendable {
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
