import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension EngineManager {
    /// Pulls `name:tag` from a registry. SDK progress callbacks are bridged to an `AsyncSequence`.
    public func pullImage(
        name: String,
        tag: String,
        platform: String? = nil,
        registryAuth: String? = nil
    ) -> AsyncThrowingStream<ImagePullEvent, Error> {
        let reference: String
        do {
            reference = try Self.normalizedReference(name: name, tag: tag)
        } catch {
            return Self.failedImageProgress(error)
        }
        let auth = authStore.authentication(reference: reference, header: registryAuth)
        let store = imageStore
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Pulling from \(Self.repository(from: reference))", id: tag))

                    let ociPlatform: Platform? = {
                        if let platform, !platform.isEmpty {
                            return try? Platform(from: platform)
                        }
                        return Platform.current
                    }()

                    let progressState = ProgressAccumulator()
                    let image = try await store.pull(
                        reference: reference,
                        platform: ociPlatform,
                        auth: auth,
                        progress: { events in
                            let snapshot = await progressState.apply(events)
                            continuation.yield(
                                .progress(
                                    id: "download",
                                    status: "Downloading",
                                    current: snapshot.current,
                                    total: snapshot.total
                                )
                            )
                        }
                    )

                    continuation.yield(.status("Digest: \(image.digest)", id: nil))
                    continuation.yield(.status("Status: Downloaded newer image for \(reference)", id: nil))
                    await self.publish(
                        EngineEvent(
                            type: "image",
                            action: "pull",
                            actorID: image.digest,
                            attributes: ["name": reference]
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RegistryErrorMapper.map(error, reference: reference, operation: .pull))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Local OCI images grouped by digest, with size / created metadata.
    /// `all: false` hides dangling (untagged) images, matching `GET /images/json`.
    public func listImages(all: Bool = true, filters: [String: [String]] = [:]) async throws -> [EngineImageSummary] {
        let groups = try await imagesGroupedByDigest()
        var summaries: [EngineImageSummary] = []
        summaries.reserveCapacity(groups.count)
        for (digest, members) in groups {
            guard let primary = members.first else { continue }
            let tags = Self.uniqueDisplayTags(members.map(\.reference))
            let repoDigests = members.map { "\(Self.repository(from: $0.reference))@\(digest)" }
            summaries.append(
                EngineImageSummary(
                    id: digest,
                    repoTags: Array(Set(tags)).sorted(),
                    repoDigests: Array(Set(repoDigests)).sorted(),
                    created: await Self.createdDate(of: primary),
                    size: await Self.totalSize(of: primary)
                )
            )
        }
        var result = summaries.sorted { $0.id < $1.id }
        if let refs = filters["reference"], !refs.isEmpty {
            result = result.filter { summary in
                refs.contains { needle in
                    summary.repoTags.contains { $0.contains(needle) }
                        || summary.repoDigests.contains { $0.contains(needle) }
                        || summary.id.contains(needle)
                }
            }
        }
        if FilterMatch.isTrue(filters["dangling"]) {
            result = result.filter(\.isDangling)
        } else if FilterMatch.isFalse(filters["dangling"]) || !all {
            result = result.filter { !$0.isDangling }
        }
        return result
    }

    public func inspectImage(name: String) async throws -> EngineImageInspect {
        let image = try await resolveImage(name)
        let siblings = try await imageStore.list().filter { $0.digest == image.digest }
        let tags = Self.uniqueDisplayTags(siblings.map(\.reference))
        let repoDigests = siblings.map { "\(Self.repository(from: $0.reference))@\(image.digest)" }

        let platform = await Self.preferredPlatform(for: image)
        let config = try? await image.config(for: platform)
        let created = config?.created ?? ISO8601.string(from: Date(timeIntervalSince1970: 0))

        return EngineImageInspect(
            id: image.digest,
            repoTags: Array(Set(tags)).sorted(),
            repoDigests: Array(Set(repoDigests)).sorted(),
            created: created,
            author: config?.author ?? "",
            architecture: config?.architecture ?? platform.architecture,
            os: config?.os ?? platform.os,
            size: await Self.totalSize(of: image),
            env: config?.config?.env ?? [],
            cmd: config?.config?.cmd ?? [],
            entrypoint: config?.config?.entrypoint ?? [],
            user: config?.config?.user ?? "",
            workingDir: config?.config?.workingDir ?? "",
            labels: config?.config?.labels ?? [:],
            layers: config?.rootfs.diffIDs ?? [],
            exposedPorts: await Self.exposedPorts(of: image, platform: platform)
        )
    }

    public func deleteImage(name: String) async throws -> [EngineImageDeleteItem] {
        let image = try await resolveImage(name)
        let digest = image.digest
        let reference = image.reference
        try await imageStore.delete(reference: reference, performCleanup: true)
        let remaining = (try? await imageStore.list().filter { $0.digest == digest }) ?? []
        if remaining.isEmpty {
            dropUnpackedCache(digest: digest)
        }
        await publishImage(action: "untag", digest: digest, name: reference)
        await publishImage(action: "delete", digest: digest, name: reference)
        return [
            EngineImageDeleteItem(untagged: reference, deleted: nil),
            EngineImageDeleteItem(untagged: nil, deleted: digest),
        ]
    }

    func resolveImage(_ name: String) async throws -> Containerization.Image {
        let decoded = name.removingPercentEncoding ?? name
        for candidate in Self.lookupCandidates(decoded) {
            do {
                return try await imageStore.get(reference: candidate)
            } catch let error as ContainerizationError where error.code == .notFound {
                continue
            }
        }

        let images = try await imageStore.list()
        if let match = images.first(where: { Self.matches($0, name: decoded) }) {
            return match
        }
        throw EngineError.imageNotFound("No such image: \(decoded)")
    }

    static func normalizedReference(name: String, tag: String?) throws -> String {
        do {
            var parsed = try Reference.parse(name)
            if parsed.domain == nil {
                parsed = try Reference(path: parsed.path, domain: "docker.io", tag: parsed.tag, digest: parsed.digest)
            }
            if let tag, !tag.isEmpty, parsed.tag == nil, parsed.digest == nil {
                parsed = try parsed.withTag(tag)
            }
            parsed.normalize()
            return parsed.description
        } catch {
            throw EngineError.invalidReference("invalid image reference \(name): \(error.localizedDescription)")
        }
    }

    static func lookupCandidates(_ name: String) -> [String] {
        var candidates = [name]
        if !name.contains(":"), !name.contains("@"), !name.hasPrefix("sha256:") {
            candidates.append("\(name):latest")
        }
        if let normalized = try? normalizedReference(name: name, tag: name.contains(":") ? nil : "latest") {
            candidates.append(normalized)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func matches(_ image: Containerization.Image, name: String) -> Bool {
        if image.reference == name { return true }
        if image.digest == name { return true }
        if image.digest.hasSuffix(name) { return true }
        if Self.aliases(for: image.reference).contains(name) { return true }
        if !name.contains(":"), Self.aliases(for: image.reference).contains("\(name):latest") { return true }
        return false
    }

    /// Names that resolve to this reference. Short Hub names stay valid for `run`/`rmi`;
    /// they are not extra `RepoTags` in `images` / inspect.
    static func aliases(for reference: String) -> [String] {
        var tags = [reference]
        if reference.hasPrefix("docker.io/library/") {
            tags.append(String(reference.dropFirst("docker.io/library/".count)))
        }
        if reference.hasPrefix("registry-1.docker.io/library/") {
            tags.append(String(reference.dropFirst("registry-1.docker.io/library/".count)))
        }
        if reference.hasPrefix("docker.io/") {
            tags.append(String(reference.dropFirst("docker.io/".count)))
        }
        return tags
    }

    /// One row per stored tag. Prefer the fully-qualified name when a Hub short alias is also stored.
    static func uniqueDisplayTags(_ references: [String]) -> [String] {
        let stored = Array(Set(references))
        return stored.filter { tag in
            if isDigestReference(tag) { return false }
            return !stored.contains { other in
                other != tag && aliases(for: other).contains(tag)
            }
        }.sorted()
    }

    static func isDigestReference(_ reference: String) -> Bool {
        reference.hasPrefix("sha256:") && !reference.contains("/")
    }

    static func repository(from reference: String) -> String {
        if let at = reference.firstIndex(of: "@") {
            return String(reference[..<at])
        }
        if let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") {
            return String(reference[..<colon])
        }
        return reference
    }

    static func preferredPlatform(for image: Containerization.Image) async -> Platform {
        if let _ = try? await image.config(for: .current) {
            return .current
        }
        if let index = try? await image.index(),
            let platform = index.manifests.compactMap(\.platform).first
        {
            return platform
        }
        return .current
    }

    static func createdDate(of image: Containerization.Image) async -> Date {
        let platform = await preferredPlatform(for: image)
        guard let created = try? await image.config(for: platform).created else {
            return Date(timeIntervalSince1970: 0)
        }
        return ISO8601.parse(created) ?? Date(timeIntervalSince1970: 0)
    }

    static func totalSize(of image: Containerization.Image) async -> Int64 {
        guard let digests = try? await image.referencedDigests() else { return 0 }
        var total: Int64 = 0
        for digest in Set(digests) {
            guard let content = try? await image.getContent(digest: digest) else { continue }
            total += Int64((try? content.size()) ?? 0)
        }
        return total
    }

    /// Docker stores `ExposedPorts` on the image config; OCI ImageConfig drops that field.
    static func exposedPorts(of image: Containerization.Image, platform: Platform) async -> [EnginePortBinding] {
        guard let manifest = try? await image.manifest(for: platform),
            let content = try? await image.getContent(digest: manifest.config.digest),
            let blob: ImageExposedPortsBlob = try? content.decode()
        else {
            return []
        }
        var ports: [EnginePortBinding] = []
        for key in blob.config?.ExposedPorts?.keys.sorted() ?? [] {
            if let parsed = try? EnginePortBinding.parseExposed(key) {
                ports.append(parsed)
            }
        }
        return ports
    }

    public func imageHistory(name: String) async throws -> [EngineImageHistoryItem] {
        let image = try await resolveImage(name)
        let platform = await Self.preferredPlatform(for: image)
        let manifest = try await image.manifest(for: platform)
        let configBlob = try await image.getContent(digest: manifest.config.digest)
        let config: ContainerizationOCI.Image = try configBlob.decode()
        var layerSizes: [Int64] = []
        layerSizes.reserveCapacity(manifest.layers.count)
        for layer in manifest.layers {
            let content: Content? = ImageLayerSize.isGzip(layer.mediaType) ? try? await image.getContent(digest: layer.digest) : nil
            layerSizes.append(ImageLayerSize.uncompressed(layer, content: content))
        }
        return EngineImageHistoryItem.from(
            history: config.history ?? [],
            layerSizes: layerSizes,
            imageDigest: image.digest,
            tags: [image.reference]
        )
    }

    public func tagImage(name: String, repo: String, tag: String?) async throws {
        let image = try await resolveImage(name)
        let newReference = try Self.normalizedReference(name: repo, tag: tag ?? "latest")
        _ = try await imageStore.tag(existing: image.reference, new: newReference)
        await publish(
            EngineEvent(
                type: "image",
                action: "tag",
                actorID: image.digest,
                attributes: ["name": newReference]
            )
        )
    }

    public func pushImage(
        name: String,
        tag: String?,
        registryAuth: String? = nil
    ) -> AsyncThrowingStream<ImagePullEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var reference = name
                do {
                    let image = try await self.resolveImage(name)
                    reference = image.reference
                    if let tag, !tag.isEmpty {
                        reference = try Self.normalizedReference(name: Self.repository(from: reference), tag: tag)
                    }
                    let auth = self.authStore.authentication(reference: reference, header: registryAuth)
                    continuation.yield(.status("The push refers to repository [\(Self.repository(from: reference))]", id: nil))

                    let progressState = ProgressAccumulator()
                    try await self.imageStore.push(
                        reference: reference,
                        platform: Platform.current,
                        auth: auth,
                        progress: { events in
                            let snapshot = await progressState.apply(events)
                            continuation.yield(
                                .progress(
                                    id: "upload",
                                    status: "Pushing",
                                    current: snapshot.current,
                                    total: snapshot.total
                                )
                            )
                        }
                    )
                    continuation.yield(.status("Digest: \(image.digest)", id: nil))
                    await self.publish(
                        EngineEvent(
                            type: "image",
                            action: "push",
                            actorID: image.digest,
                            attributes: ["name": reference]
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: RegistryErrorMapper.map(error, reference: reference, operation: .push))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func failedImageProgress(_ error: Error) -> AsyncThrowingStream<ImagePullEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    public func pruneImages(danglingOnly: Bool, until: Date?) async throws -> EngineImagePruneResult {
        var deleted: [EngineImageDeleteItem] = []
        var reclaimed: Int64 = 0

        for (digest, members) in try await imagesGroupedByDigest() {
            guard let primary = members.first else { continue }
            if danglingOnly, !Self.uniqueDisplayTags(members.map(\.reference)).isEmpty { continue }
            if imageInUse(digest: digest, members: members) { continue }
            if let until {
                let created = await Self.createdDate(of: primary)
                if created >= until { continue }
            }

            let size = await Self.totalSize(of: primary)
            var leftover = false
            for image in members {
                do {
                    try await imageStore.delete(reference: image.reference, performCleanup: false)
                    deleted.append(EngineImageDeleteItem(untagged: image.reference, deleted: nil))
                    await publishImage(action: "untag", digest: digest, name: image.reference)
                } catch {
                    leftover = true
                }
            }
            if !leftover {
                deleted.append(EngineImageDeleteItem(untagged: nil, deleted: digest))
                reclaimed += size
                dropUnpackedCache(digest: digest)
                await publishImage(action: "delete", digest: digest, name: digest)
            }
        }

        _ = try await imageStore.cleanUpOrphanedBlobs()
        return EngineImagePruneResult(deleted: deleted, spaceReclaimed: reclaimed)
    }

    private func imageInUse(digest: String, members: [Containerization.Image]) -> Bool {
        containers.values.contains { container in
            if !container.imageID.isEmpty, container.imageID == digest { return true }
            guard !container.image.isEmpty else { return false }
            return members.contains { Self.matches($0, name: container.image) }
        }
    }

    private func imagesGroupedByDigest() async throws -> [(digest: String, members: [Containerization.Image])] {
        var groups: [String: [Containerization.Image]] = [:]
        for image in try await imageStore.list() {
            groups[image.digest, default: []].append(image)
        }
        return groups.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
    }

    public func searchImages(term: String, limit: Int) async throws -> [EngineImageSearchResult] {
        var components = URLComponents(string: "https://hub.docker.com/v2/search/repositories/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "page_size", value: String(max(1, min(limit, 100)))),
        ]
        guard let url = components.url else {
            throw EngineError.invalidReference("invalid search term")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EngineError.pullFailed("Docker Hub search failed")
        }

        let decoded = try JSONDecoder().decode(HubSearchResponse.self, from: data)
        return (decoded.results ?? []).map {
            EngineImageSearchResult(
                name: $0.repoName ?? $0.name ?? "",
                description: $0.shortDescription ?? $0.description ?? "",
                starCount: $0.starCount ?? 0,
                isOfficial: $0.isOfficial ?? false,
                isAutomated: $0.isAutomated ?? false
            )
        }
    }

    public func exportImages(names: [String]) async throws -> Data {
        guard !names.isEmpty else {
            throw EngineError.invalidReference("at least one image name is required")
        }
        var references: [String] = []
        for name in names {
            references.append(try await resolveImage(name).reference)
        }
        let work = try Self.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        let oci = work.appendingPathComponent("oci", isDirectory: true)
        try FileManager.default.createDirectory(at: oci, withIntermediateDirectories: true)
        // Pulls are platform-filtered; export the host platform so missing sibling manifests are skipped.
        try await imageStore.save(references: references, out: oci, platform: .current)

        let tar = work.appendingPathComponent("images.tar")
        try Self.runTar(["-C", oci.path, "-cf", tar.path, "."])
        return try Data(contentsOf: tar)
    }

    public func loadImages(from tar: Data) async throws -> [String] {
        guard !tar.isEmpty else {
            throw EngineError.loadFailed("empty image archive")
        }
        let work = try Self.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let tarFile = work.appendingPathComponent("images.tar")
        try tar.write(to: tarFile)
        return try await loadImages(fromArchive: tarFile)
    }

    public func loadImages(fromArchive tar: URL) async throws -> [String] {
        guard (try? TarArchive.size(of: tar)) ?? 0 > 0 else {
            throw EngineError.loadFailed("empty image archive")
        }
        let work = try Self.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        let dest = work.appendingPathComponent("oci", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Self.runTar(["-C", dest.path, "-xf", tar.path])

        let root = Self.findOCILayout(in: dest) ?? dest
        let images = try await imageStore.load(from: root)
        for image in images {
            await publish(
                EngineEvent(
                    type: "image",
                    action: "load",
                    actorID: image.digest,
                    attributes: ["name": image.reference]
                )
            )
        }
        return images.map(\.reference)
    }

    private static func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func runTar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "tar failed"
            throw EngineError.exportFailed(message)
        }
    }

    private static func findOCILayout(in directory: URL) -> URL? {
        let layout = directory.appendingPathComponent("oci-layout")
        if FileManager.default.fileExists(atPath: layout.path) {
            return directory
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.hasDirectoryPath {
            if FileManager.default.fileExists(atPath: child.appendingPathComponent("oci-layout").path) {
                return child
            }
        }
        return nil
    }
}

private struct HubSearchResponse: Decodable {
    let results: [HubSearchResult]?

    struct HubSearchResult: Decodable {
        let repoName: String?
        let name: String?
        let shortDescription: String?
        let description: String?
        let starCount: Int?
        let isOfficial: Bool?
        let isAutomated: Bool?

        enum CodingKeys: String, CodingKey {
            case repoName = "repo_name"
            case name
            case shortDescription = "short_description"
            case description
            case starCount = "star_count"
            case isOfficial = "is_official"
            case isAutomated = "is_automated"
        }
    }
}

private struct ImageExposedPortsBlob: Decodable {
    var config: Config?

    struct Config: Decodable {
        var ExposedPorts: [String: Empty]?

        struct Empty: Decodable {}
    }
}

/// Serializes SDK `ProgressEvent` batches into running totals for Docker-style progress.
actor ProgressAccumulator {
    private var current: Int64 = 0
    private var total: Int64 = 0

    func apply(_ events: [ProgressEvent]) -> (current: Int64, total: Int64) {
        for event in events {
            switch event {
            case .addSize(let value):
                current += value
            case .addTotalSize(let value):
                total += value
            case .addItems, .addTotalItems:
                break
            }
        }
        return (current, total)
    }
}
