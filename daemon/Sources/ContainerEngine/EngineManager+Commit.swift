import Containerization
import ContainerizationOCI
import Foundation

extension EngineManager {
    public func commitContainer(_ idOrName: String, spec: EngineCommitSpec) async throws -> String {
        var preview = CommitRuntimeConfig()
        try CommitConfig.applyInstructions(spec.changes, to: &preview)

        let container = try requireFilesystem(idOrName)
        return try await withSnapshot(container) { changes, root in
            try await self.writeCommittedImage(
                container: container,
                spec: spec,
                root: root,
                changes: changes
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

        let ingested = try await withScratch("macker-layer") { work in
            try await self.ingestImage(
                config: imageFile,
                parentLayers: manifest.layers,
                platform: platform,
                layer: try self.stageLayer(root: root, changes: changes, work: work),
                history: CommitHistory(
                    created: ISO8601.string(from: createdAt),
                    createdBy: "#(nop) COMMIT",
                    author: spec.author.isEmpty ? imageFile.author : spec.author,
                    comment: spec.comment.isEmpty ? nil : spec.comment,
                    emptyLayer: nil
                )
            )
        }

        let image: Containerization.Image
        let reference: String
        if let repo = spec.repo, !repo.isEmpty {
            reference = try Self.normalizedReference(name: repo, tag: spec.tag)
            image = try await imageStore.create(description: .init(reference: reference, descriptor: ingested.descriptor))
        } else {
            reference = ingested.descriptor.digest
            image = try await adoptImage(ingested.descriptor)
        }
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
}
