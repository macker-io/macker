import Containerization
import ContainerizationOCI
import Foundation

/// The image a stage has produced so far, plus the scopes used to expand instructions.
struct BuildStageState: Sendable {
    var reference: String
    var digest: String
    var config: CommitImageFile
    var layers: [Descriptor]
    var platform: Platform
    var shell: [String]
    var args: [String: String]

    var runtime: CommitRuntimeConfig { config.config ?? CommitRuntimeConfig() }

    var workingDir: String {
        let dir = runtime.WorkingDir ?? ""
        return dir.isEmpty ? "/" : dir
    }

    /// ENV wins over ARG, matching Docker's expansion scope.
    var variables: [String: String] {
        var values = args
        for item in runtime.Env ?? [] {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            values[String(key)] = parts.count > 1 ? String(parts[1]) : ""
        }
        return values
    }
}

extension EngineManager {
    /// Marks containers the builder creates for `RUN`, so a leaked one is recognizable.
    static let buildContainerLabel = "io.macker.build"
    static let defaultBuildShell = ["/bin/sh", "-c"]
    /// Sparse ext4 used when a stage rootfs has to be materialized on the host for `COPY --from`.
    static let buildUnpackBytes: UInt64 = 8 * 1024 * 1024 * 1024

    /// `POST /build`: pick a backend, then produce an image.
    /// `contextArchive` is the uploaded context tar; the caller owns its lifetime.
    public func buildImage(spec: EngineBuildSpec, contextArchive: URL) -> AsyncThrowingStream<EngineBuildEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let digest = try await self.performBuild(spec: spec, contextArchive: contextArchive) { event in
                        continuation.yield(event)
                    }
                    continuation.yield(.built(digest))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `POST /build/prune`: drop unused classic-builder intermediate images.
    public func pruneBuildCache(all: Bool = false, filters: [String: [String]] = [:]) async throws -> EngineBuildPruneResult {
        var cache = BuildCache(store: imageStore.path)
        let stored = try await imageStore.list()
        var tagged: Set<String> = []
        for image in stored where !Self.isDigestReference(image.reference) {
            tagged.insert(image.digest)
        }
        let until = filters["until"]?.compactMap(ISO8601.parseTimestamp).min()
        let ids = filters["id"] ?? []

        var deleted: [String] = []
        var reclaimed: Int64 = 0
        var dropped: Set<String> = []

        for reference in cache.references {
            guard let image = stored.first(where: { $0.reference == reference }) else {
                dropped.insert(reference)
                continue
            }
            if let pruned = await pruneBuildCacheImage(
                image, tagged: tagged, until: until, ids: ids, cacheReference: reference
            ) {
                deleted.append(pruned.digest)
                reclaimed += pruned.size
                if let drop = pruned.drop { dropped.insert(drop) }
            }
        }
        if all {
            let cached = Set(cache.references)
            for image in stored where Self.isDigestReference(image.reference) && !cached.contains(image.reference) {
                if let pruned = await pruneBuildCacheImage(
                    image, tagged: tagged, until: until, ids: ids, cacheReference: nil
                ) {
                    deleted.append(pruned.digest)
                    reclaimed += pruned.size
                }
            }
        }
        cache.forget(references: dropped)
        let cleanup = try await imageStore.cleanUpOrphanedBlobs()
        reclaimed += Int64(cleanup.freed)
        return EngineBuildPruneResult(deleted: deleted, spaceReclaimed: reclaimed)
    }

    private func pruneBuildCacheImage(
        _ image: Containerization.Image,
        tagged: Set<String>,
        until: Date?,
        ids: [String],
        cacheReference: String?
    ) async -> (digest: String, size: Int64, drop: String?)? {
        if tagged.contains(image.digest) { return nil }
        if containers.values.contains(where: { $0.imageID == image.digest || $0.image == image.reference }) {
            return nil
        }
        if let until {
            let created = await Self.createdDate(of: image)
            if created >= until { return nil }
        }
        if !ids.isEmpty, !Self.buildCacheIDMatches(image.digest, ids: ids) { return nil }

        let size = await Self.totalSize(of: image)
        try? await imageStore.delete(reference: image.reference, performCleanup: false)
        await publish(
            EngineEvent(type: "image", action: "delete", actorID: image.digest, attributes: ["name": image.reference])
        )
        return (image.digest, size, cacheReference)
    }

    static func buildCacheIDMatches(_ digest: String, ids: [String]) -> Bool {
        let hex = digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
        return ids.contains { id in
            guard !id.isEmpty else { return false }
            let needle = id.hasPrefix("sha256:") ? String(id.dropFirst("sha256:".count)) : id
            guard !needle.isEmpty else { return false }
            return digest == id || digest.hasPrefix(id) || hex.hasPrefix(needle)
        }
    }

    private func performBuild(
        spec: EngineBuildSpec,
        contextArchive: URL,
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws -> String {
        try Self.validateBuildSpec(spec)
        return try await withScratch("macker-build") { work in
            let context = work.appendingPathComponent("context", isDirectory: true)
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try TarArchive.extract(contextArchive, to: context)
            let text = try BuildContext.dockerfile(in: context, named: spec.dockerfile)
            switch try BuildBackend.select(dockerfile: text) {
            case .classic:
                let dockerfile = try Dockerfile.parse(text)
                try BuildBackend.rejectBuildKitInstructions(dockerfile)
                return try await self.classicBuild(
                    dockerfile,
                    spec: spec,
                    context: context,
                    work: work,
                    emit: emit
                )
            case .buildkit:
                throw EngineError.notImplemented(
                    BuildBackend.unsupportedMessage("BuildKit")
                )
            }
        }
    }

    /// Classic Docker builder: one instruction, one layer; each `RUN` is a MicroVM.
    private func classicBuild(
        _ dockerfile: Dockerfile,
        spec: EngineBuildSpec,
        context: URL,
        work: URL,
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws -> String {
        let limit: Int
        if let target = spec.target, !target.isEmpty {
            guard let stage = dockerfile.stage(named: target) else {
                throw EngineError.invalidArgument("failed to reach build target \(target) in Dockerfile")
            }
            limit = stage.index
        } else {
            limit = dockerfile.stages.count - 1
        }

        let stages = Array(dockerfile.stages.prefix(limit + 1))
        let total = stages.reduce(0) { $0 + 1 + $1.instructions.count }
        let globals = Self.declaredArgs(dockerfile.globalArgs, provided: spec.buildArgs)
        var cache = BuildCache(store: imageStore.path)
        var completed: [String: String] = [:]
        var step = 0
        var last: BuildStageState?

        for stage in stages {
            step += 1
            emit(.status("Step \(step)/\(total) : FROM \(Self.describeFrom(stage))"))
            var state = try await beginStage(stage, globals: globals, completed: completed, spec: spec, emit: emit)
            emit(.status(" ---> \(Self.shortDigest(state.digest))"))

            for instruction in stage.instructions {
                try Task.checkCancellation()
                step += 1
                let resolved = Self.expand(instruction, variables: state.variables)
                emit(.status("Step \(step)/\(total) : \(resolved.source)"))
                try await apply(
                    resolved,
                    state: &state,
                    spec: spec,
                    context: context,
                    work: work,
                    stages: completed,
                    cache: &cache,
                    step: step,
                    emit: emit
                )
                emit(.status(" ---> \(Self.shortDigest(state.digest))"))
            }

            completed[String(stage.index)] = state.reference
            if let name = stage.name {
                completed[name] = state.reference
            }
            last = state
        }

        guard var final = last else {
            throw EngineError.invalidArgument("Dockerfile contains no FROM instruction")
        }
        if !spec.labels.isEmpty {
            var runtime = final.runtime
            runtime.Labels = CommitConfig.merge(runtime.Labels ?? [:], spec.labels)
            final.config.config = runtime
            try await commitStep(
                state: &final,
                layer: nil,
                createdBy: "/bin/sh -c #(nop)  LABEL \(spec.labels.keys.sorted().joined(separator: " "))",
                cache: &cache,
                cacheKey: nil
            )
        }

        return try await finishBuild(final, tags: spec.tags, emit: emit)
    }

    /// Tags and events every backend should emit so `macker run` can find the image.
    private func finishBuild(
        _ state: BuildStageState,
        tags: [String],
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws -> String {
        for tag in tags {
            let reference = try Self.normalizedReference(name: tag, tag: "latest")
            _ = try await imageStore.tag(existing: state.reference, new: reference)
            await publish(
                EngineEvent(type: "image", action: "tag", actorID: state.digest, attributes: ["name": reference])
            )
        }
        await publish(
            EngineEvent(type: "image", action: "build", actorID: state.digest, attributes: ["name": state.reference])
        )
        emit(.status("Successfully built \(Self.shortDigest(state.digest))"))
        for tag in tags {
            emit(.status("Successfully tagged \(tag)"))
        }
        return state.digest
    }

    private func beginStage(
        _ stage: DockerfileStage,
        globals: [String: String],
        completed: [String: String],
        spec: EngineBuildSpec,
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws -> BuildStageState {
        let base = Shellwords.expand(stage.base, variables: globals)
        if let platform = stage.platform, !platform.isEmpty {
            emit(.status("[Warning] --platform=\(platform) is ignored; macker builds for the host platform"))
        }

        var state: BuildStageState
        if let previous = completed[base.lowercased()] {
            state = try await stageState(reference: previous)
        } else if base == "scratch" {
            state = Self.scratchState(platform: try Self.buildPlatform(spec.platform))
        } else {
            let image = try await baseImage(base, pull: spec.pull, platform: spec.platform, emit: emit)
            state = try await stageState(image: image)
        }
        state.args = globals
        return state
    }

    private func apply(
        _ instruction: DockerfileInstruction,
        state: inout BuildStageState,
        spec: EngineBuildSpec,
        context: URL,
        work: URL,
        stages: [String: String],
        cache: inout BuildCache,
        step: Int,
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws {
        if instruction.name == "ARG" {
            let declared = try Dockerfile.parseArg(instruction)
            let value = spec.buildArgs[declared.name] ?? declared.defaultValue ?? ""
            state.args[declared.name] = value
            let key = spec.noCache
                ? nil
                : BuildCache.key(parent: state.digest, instruction: instruction.source, inputs: [value])
            if let key, try await useCache(key, cache: cache, state: &state, emit: emit) { return }
            try await commitStep(
                state: &state,
                layer: nil,
                createdBy: "/bin/sh -c #(nop)  \(instruction.source)",
                cache: &cache,
                cacheKey: key
            )
            return
        }

        let cacheKey = spec.noCache
            ? nil
            : BuildCache.key(parent: state.digest, instruction: instruction.source)

        switch instruction.name {
        case "RUN":
            if let cacheKey, try await useCache(cacheKey, cache: cache, state: &state, emit: emit) { return }
            let stepWork = try Self.stepDirectory(work, step: step)
            let layer = try await runInstruction(instruction, state: state, spec: spec, work: stepWork, emit: emit)
            try await commitStep(
                state: &state,
                layer: layer,
                createdBy: Self.runCreatedBy(instruction, shell: state.shell),
                cache: &cache,
                cacheKey: cacheKey
            )
        case "COPY", "ADD":
            let stepWork = try Self.stepDirectory(work, step: step)
            let staged = try await stageCopy(
                instruction,
                state: state,
                context: context,
                stages: stages,
                work: stepWork
            )
            let fingerprint = try BuildCache.fingerprint(of: staged)
            let key = spec.noCache
                ? nil
                : BuildCache.key(parent: state.digest, instruction: instruction.source, inputs: [fingerprint])
            if let key, try await useCache(key, cache: cache, state: &state, emit: emit) { return }
            try await commitStep(
                state: &state,
                layer: try stageLayer(from: staged, work: stepWork, ownership: Self.copyOwnership(instruction)),
                createdBy: "/bin/sh -c #(nop) \(instruction.source)",
                cache: &cache,
                cacheKey: key
            )
        case "WORKDIR":
            if let cacheKey, try await useCache(cacheKey, cache: cache, state: &state, emit: emit) { return }
            let stepWork = try Self.stepDirectory(work, step: step)
            let directory = Self.absolutePath(instruction.arguments, workingDir: state.workingDir)
            var runtime = state.runtime
            runtime.WorkingDir = directory
            state.config.config = runtime
            try await commitStep(
                state: &state,
                layer: try Self.stageDirectory(directory, work: stepWork).map {
                    try stageLayer(from: $0, work: stepWork, ownership: .root)
                },
                createdBy: "/bin/sh -c #(nop)  WORKDIR \(directory)",
                cache: &cache,
                cacheKey: cacheKey
            )
        default:
            if let cacheKey, try await useCache(cacheKey, cache: cache, state: &state, emit: emit) { return }
            try applyMetadata(instruction, state: &state)
            try await commitStep(
                state: &state,
                layer: nil,
                createdBy: "/bin/sh -c #(nop)  \(instruction.source)",
                cache: &cache,
                cacheKey: cacheKey
            )
        }
    }

    private func applyMetadata(_ instruction: DockerfileInstruction, state: inout BuildStageState) throws {
        guard instruction.flags.isEmpty else {
            throw EngineError.invalidArgument(
                "\(instruction.name) does not support --\(instruction.flags.names.joined(separator: " --"))"
            )
        }
        var runtime = state.runtime
        switch instruction.name {
        case "MAINTAINER":
            state.config.author = instruction.arguments
        case "SHELL":
            guard Shellwords.isJSONForm(instruction.arguments) else {
                throw EngineError.invalidArgument("SHELL requires the JSON array form, e.g. SHELL [\"/bin/bash\", \"-c\"]")
            }
            let shell = try Shellwords.command(instruction.arguments, shell: [])
            guard !shell.isEmpty else {
                throw EngineError.invalidArgument("SHELL requires at least one element")
            }
            state.shell = shell
            runtime.Shell = shell
        case "CMD":
            runtime.Cmd = try Shellwords.command(instruction.arguments, shell: state.shell)
        case "ENTRYPOINT":
            runtime.Entrypoint = try Shellwords.command(instruction.arguments, shell: state.shell)
            runtime.Cmd = []
        default:
            try CommitConfig.applyInstruction(instruction.source, to: &runtime)
        }
        state.config.config = runtime
    }

    /// Reuses the image a previous build recorded for this step.
    private func useCache(
        _ key: String,
        cache: BuildCache,
        state: inout BuildStageState,
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws -> Bool {
        guard let reference = cache.reference(for: key),
            let image = try? await imageStore.get(reference: reference)
        else {
            return false
        }
        let shell = state.shell
        let args = state.args
        state = try await stageState(image: image)
        state.shell = state.runtime.Shell ?? shell
        state.args = args
        emit(.status(" ---> Using cache"))
        return true
    }

    /// Ingests the current config (and optional layer) as the stage's new image.
    private func commitStep(
        state: inout BuildStageState,
        layer: ImageLayerBlob?,
        createdBy: String,
        cache: inout BuildCache,
        cacheKey: String?
    ) async throws {
        let now = Date()
        var config = state.config
        config.created = ISO8601.string(from: now)
        let ingested = try await ingestImage(
            config: config,
            parentLayers: state.layers,
            platform: state.platform,
            layer: layer,
            history: CommitHistory(
                created: ISO8601.string(from: now),
                createdBy: createdBy,
                author: config.author,
                comment: nil,
                emptyLayer: nil
            )
        )
        let image = try await adoptImage(ingested.descriptor)
        state.reference = image.reference
        state.digest = image.digest
        state.config = ingested.config
        state.layers = ingested.layers
        if let cacheKey {
            cache.record(key: cacheKey, reference: image.reference)
        }
    }

    func stageState(reference: String) async throws -> BuildStageState {
        try await stageState(image: try await resolveImage(reference))
    }

    func stageState(image: Containerization.Image) async throws -> BuildStageState {
        let platform = await Self.preferredPlatform(for: image)
        let manifest = try await image.manifest(for: platform)
        let config: CommitImageFile = try await image.getContent(digest: manifest.config.digest).decode()
        return BuildStageState(
            reference: image.reference,
            digest: image.digest,
            config: config,
            layers: manifest.layers,
            platform: platform,
            shell: config.config?.Shell ?? Self.defaultBuildShell,
            args: [:]
        )
    }

    private func baseImage(
        _ name: String,
        pull: Bool,
        platform: String?,
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws -> Containerization.Image {
        if !pull, let local = try? await resolveImage(name) {
            return local
        }
        emit(.status("Pulling from \(Self.repository(from: (try? Self.normalizedReference(name: name, tag: "latest")) ?? name))"))
        for try await event in pullImage(name: name, tag: "latest", platform: platform) {
            if case .status(let text, _) = event {
                emit(.status(text))
            }
        }
        return try await resolveImage(name)
    }

    private static func scratchState(platform: Platform) -> BuildStageState {
        BuildStageState(
            reference: "scratch",
            digest: "scratch",
            config: CommitImageFile(
                created: nil,
                author: nil,
                architecture: platform.architecture,
                os: platform.os,
                osVersion: nil,
                osFeatures: nil,
                variant: platform.variant,
                config: CommitRuntimeConfig(),
                rootfs: CommitRootFS(type: "layers", diffIDs: []),
                history: []
            ),
            layers: [],
            platform: platform,
            shell: defaultBuildShell,
            args: [:]
        )
    }

    static func buildPlatform(_ raw: String?) throws -> Platform {
        guard let raw, !raw.isEmpty else { return .current }
        guard let parsed = try? Platform(from: raw) else {
            throw EngineError.invalidArgument("invalid platform \(raw)")
        }
        return parsed
    }

    /// Global `ARG`s take the value passed with `--build-arg`, else their default.
    public static func unsupportedBuildNetwork(_ raw: String) -> String? {
        let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode.hasPrefix("container:") || mode == "macvlan" || mode == "ipvlan" {
            return mode
        }
        return nil
    }

    static func validateBuildSpec(_ spec: EngineBuildSpec) throws {
        if let mode = unsupportedBuildNetwork(spec.networkMode) {
            throw EngineError.notImplemented("network mode \(mode) is not implemented")
        }
        if spec.memory < 0 {
            throw EngineError.invalidArgument("invalid memory: \(spec.memory)")
        }
        for extra in spec.extraHosts {
            _ = try EngineExtraHost.parse(extra)
        }
    }

    static func declaredArgs(_ declared: [DockerfileArg], provided: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for arg in declared {
            values[arg.name] = provided[arg.name] ?? arg.defaultValue ?? ""
        }
        return values
    }

    static func expand(_ instruction: DockerfileInstruction, variables: [String: String]) -> DockerfileInstruction {
        guard Dockerfile.expandedInstructions.contains(instruction.name) else { return instruction }
        var resolved = instruction
        resolved.arguments = Shellwords.expand(instruction.arguments, variables: variables)
        resolved.flags = DockerfileFlags(
            instruction.flags.values.mapValues { Shellwords.expand($0, variables: variables) }
        )
        return resolved
    }

    static func runCreatedBy(_ instruction: DockerfileInstruction, shell: [String]) -> String {
        if Shellwords.isJSONForm(instruction.arguments) {
            return instruction.arguments
        }
        return "\(shell.joined(separator: " ")) \(instruction.arguments)"
    }

    static func describeFrom(_ stage: DockerfileStage) -> String {
        guard let name = stage.name else { return stage.base }
        return "\(stage.base) AS \(name)"
    }

    static func shortDigest(_ digest: String) -> String {
        let body = digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
        return String(body.prefix(12))
    }

    /// Resolves a Dockerfile path argument against the current `WORKDIR`.
    static func absolutePath(_ path: String, workingDir: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let joined = trimmed.hasPrefix("/") ? trimmed : "\(workingDir == "/" ? "" : workingDir)/\(trimmed)"
        return (try? ArchivePath.normalize(joined).path) ?? joined
    }

    /// Docker creates a missing `WORKDIR`; the layer holds the directory chain.
    static func stageDirectory(_ path: String, work: URL) throws -> URL? {
        guard path != "/" else { return nil }
        let staged = work.appendingPathComponent("workdir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: FSInventory.hostURL(root: staged, path: path),
            withIntermediateDirectories: true
        )
        return staged
    }

    static func stepDirectory(_ work: URL, step: Int) throws -> URL {
        let url = work.appendingPathComponent("step-\(step)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
