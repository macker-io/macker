import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Foundation
import SystemPackage

/// A parsed `COPY` / `ADD`.
struct BuildCopy: Sendable {
    var sources: [String]
    var destination: String
    var from: String?
    var chmod: UInt16?
    var isAdd: Bool
}

extension EngineManager {
    /// Runs one `RUN` in a throwaway MicroVM and returns the layer holding its changes.
    func runInstruction(
        _ instruction: DockerfileInstruction,
        state: BuildStageState,
        work: URL,
        emit: @escaping @Sendable (EngineBuildEvent) -> Void
    ) async throws -> ImageLayerBlob? {
        guard instruction.flags.isEmpty else {
            throw EngineError.notImplemented(
                BuildBackend.unsupportedMessage("RUN --\(instruction.flags.names.joined(separator: " --"))")
            )
        }
        let command = try Shellwords.command(instruction.arguments, shell: state.shell)
        guard !command.isEmpty else {
            throw EngineError.invalidArgument("RUN requires a command")
        }

        let created = try await createContainer(
            EngineContainerCreateSpec(
                name: "macker-build-\(UUID().uuidString.prefix(8).lowercased())",
                image: state.reference,
                env: Self.buildArgEnvironment(state),
                cmd: command,
                entrypoint: [],
                labels: [Self.buildContainerLabel: "1"]
            )
        )
        let id = created.id
        do {
            let session = subscribeAttach(containerID: id, tty: false, stdin: false, kind: .logs)
            let pump = Task {
                for await chunk in session.chunks {
                    emit(.output(chunk.data))
                }
            }
            _ = try await startContainer(id)
            let code = try await waitContainer(id)
            await pump.value
            guard code == 0 else {
                throw EngineError.runtimeUnavailable(
                    "The command '\(command.joined(separator: " "))' returned a non-zero code: \(code)"
                )
            }
            let layer = try await snapshotBuildLayer(id, work: work)
            try? await deleteContainer(id, force: true, removeAnonymousVolumes: true)
            return layer
        } catch {
            try? await deleteContainer(id, force: true, removeAnonymousVolumes: true)
            throw error
        }
    }

    /// Stages the files a `COPY` / `ADD` adds, as a tree rooted at the container root.
    func stageCopy(
        _ instruction: DockerfileInstruction,
        state: BuildStageState,
        context: URL,
        stages: [String: String],
        work: URL
    ) async throws -> URL {
        let copy = try Self.parseCopy(instruction)
        let staged = work.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let existingDirectory = try await destinationIsExistingDirectory(copy, state: state)

        guard let from = copy.from, !from.isEmpty else {
            try await Self.stage(
                copy,
                sourceRoot: context,
                workingDir: state.workingDir,
                into: staged,
                destinationExists: existingDirectory
            )
            return staged
        }
        let reference = stages[from.lowercased()] ?? from
        try await withStageRootfs(reference, platform: state.platform) { root in
            try await Self.stage(
                copy,
                sourceRoot: root,
                workingDir: state.workingDir,
                into: staged,
                destinationExists: existingDirectory,
                allowRemote: false
            )
        }
        return staged
    }

    /// `COPY app /usr/local/bin` means "into that directory" when the stage already has
    /// one there, and "write that file" otherwise, so an ambiguous spelling has to be
    /// resolved against the stage itself. Only then, since it costs an image unpack.
    private func destinationIsExistingDirectory(_ copy: BuildCopy, state: BuildStageState) async throws -> Bool {
        guard !Self.spelledAsDirectory(copy.destination), state.digest != "scratch" else { return false }
        let path = Self.absolutePath(copy.destination, workingDir: state.workingDir)
        guard path != "/" else { return true }
        return try await withStageRootfs(state.reference, platform: state.platform) { root in
            let url = FSInventory.hostURL(root: root, path: path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isSymbolicLink != true && values?.isDirectory == true
        }
    }

    /// Materializes an image (a finished stage, or any local/remote image) as a host tree.
    /// Layers are unpacked to ext4 and exported, so no MicroVM has to boot.
    func withStageRootfs<T>(
        _ reference: String,
        platform: Platform,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let image = try await resolveImage(reference)
        return try await withScratch("macker-stage-root") { work in
            let ext4 = work.appendingPathComponent("rootfs.ext4")
            _ = try await EXT4Unpacker(capacityInBytes: Self.buildUnpackBytes).unpack(image, for: platform, at: ext4)
            let tar = work.appendingPathComponent("rootfs.tar")
            try EXT4.EXT4Reader(blockDevice: FilePath(ext4.path)).export(archive: FilePath(tar.path))
            let root = work.appendingPathComponent("root", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try TarArchive.extract(tar, to: root)
            return try await body(root)
        }
    }

    private func snapshotBuildLayer(_ id: String, work: URL) async throws -> ImageLayerBlob? {
        let container = try requireFilesystem(id)
        return try await withSnapshot(container) { changes, root in
            try self.stageLayer(root: root, changes: changes, work: work)
        }
    }

    /// `RUN` sees declared build args as environment variables; `ENV` still wins.
    static func buildArgEnvironment(_ state: BuildStageState) -> [String] {
        let defined = Set(
            (state.runtime.Env ?? []).compactMap { item -> String? in
                item.split(separator: "=", maxSplits: 1).first.map(String.init)
            }
        )
        return state.args
            .filter { !defined.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    static func parseCopy(_ instruction: DockerfileInstruction) throws -> BuildCopy {
        let supported: Set<String> = ["from", "chown", "chmod"]
        if let unsupported = instruction.flags.names.first(where: { !supported.contains($0) }) {
            throw EngineError.notImplemented(
                BuildBackend.unsupportedMessage("\(instruction.name) --\(unsupported)")
            )
        }
        let tokens: [String]
        if Shellwords.isJSONForm(instruction.arguments) {
            tokens = try Shellwords.command(instruction.arguments, shell: [])
        } else {
            tokens = try Shellwords.split(instruction.arguments)
        }
        guard tokens.count >= 2 else {
            throw EngineError.invalidArgument("\(instruction.name) requires at least one source and a destination")
        }
        var chmod: UInt16?
        if let raw = instruction.flags["chmod"], !raw.isEmpty {
            guard let parsed = UInt16(raw, radix: 8) else {
                throw EngineError.invalidArgument("invalid --chmod=\(raw): expected an octal mode")
            }
            chmod = parsed
        }
        return BuildCopy(
            sources: Array(tokens.dropLast()),
            destination: tokens[tokens.count - 1],
            from: instruction.flags["from"],
            chmod: chmod,
            isAdd: instruction.name == "ADD"
        )
    }

    /// Layers are extracted by the guest as root, and a non-root host cannot record
    /// arbitrary owners, so `COPY` defaults to `0:0` like Docker and honours numeric
    /// `--chown`. User and group names would need the stage's `/etc/passwd`.
    static func copyOwnership(_ instruction: DockerfileInstruction) throws -> TarArchive.Ownership {
        guard let chown = instruction.flags["chown"], !chown.isEmpty else { return .root }
        let parts = chown.split(separator: ":", maxSplits: 1).map(String.init)
        guard let uid = Int(parts[0]), let gid = parts.count > 1 ? Int(parts[1]) : uid else {
            throw EngineError.notImplemented(
                "--chown=\(chown) needs a numeric UID[:GID]; user and group names are not resolved"
            )
        }
        return .numeric(uid: uid, gid: gid)
    }

    private struct ResolvedSource {
        var url: URL
        var name: String
        var isDirectory: Bool
        var isArchive: Bool
    }

    private static func stage(
        _ copy: BuildCopy,
        sourceRoot: URL,
        workingDir: String,
        into staged: URL,
        destinationExists: Bool = false,
        allowRemote: Bool = true
    ) async throws {
        let destination = absolutePath(copy.destination, workingDir: workingDir)
        var resolved: [ResolvedSource] = []
        var downloads: [ResolvedSource] = []

        for source in copy.sources {
            if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
                guard allowRemote else {
                    throw EngineError.invalidArgument("\(copy.isAdd ? "ADD" : "COPY") cannot fetch \(source) here")
                }
                downloads.append(
                    ResolvedSource(
                        url: url,
                        name: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent,
                        isDirectory: false,
                        isArchive: false
                    )
                )
                continue
            }
            for match in try matchSources(root: sourceRoot, pattern: source, instruction: copy.isAdd ? "ADD" : "COPY") {
                let url = FSInventory.hostURL(root: sourceRoot, path: match)
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                resolved.append(
                    ResolvedSource(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: values?.isSymbolicLink != true && values?.isDirectory == true,
                        isArchive: isArchive(match)
                    )
                )
            }
        }

        let items = resolved + downloads
        let asDirectory =
            items.count > 1
            || destinationExists
            || spelledAsDirectory(copy.destination)
            || items.contains(where: \.isDirectory)
        if asDirectory {
            try FileManager.default.createDirectory(
                at: FSInventory.hostURL(root: staged, path: destination),
                withIntermediateDirectories: true
            )
        }

        for item in resolved {
            let target = FSInventory.hostURL(root: staged, path: asDirectory ? ArchivePath.join(destination, item.name) : destination)
            if item.isDirectory {
                // Docker copies the contents of a source directory, not the directory itself.
                try mergeCopy(from: item.url, to: FSInventory.hostURL(root: staged, path: destination))
                continue
            }
            if copy.isAdd, item.isArchive {
                try TarArchive.extract(item.url, to: FSInventory.hostURL(root: staged, path: destination))
                continue
            }
            try place(item.url, at: target)
        }
        for item in downloads {
            let target = FSInventory.hostURL(root: staged, path: asDirectory ? ArchivePath.join(destination, item.name) : destination)
            try await download(item.url, to: target)
        }
        if let chmod = copy.chmod {
            try applyMode(chmod, under: staged)
        }
    }

    /// A trailing separator asks for a directory, and so does a trailing `.` or `..`,
    /// which is how `COPY file .` lands inside `WORKDIR`.
    static func spelledAsDirectory(_ destination: String) -> Bool {
        if destination.hasSuffix("/") { return true }
        let last = destination.split(separator: "/").last.map(String.init) ?? destination
        return last == "." || last == ".."
    }

    /// Literal paths are checked directly; `*`, `?` and `**` are matched against the
    /// source tree with `.dockerignore` pattern semantics.
    static func matchSources(root: URL, pattern: String, instruction: String) throws -> [String] {
        let relative = BuildContext.normalize(pattern)
        guard !relative.isEmpty, !relative.hasPrefix("../"), relative != ".." else {
            throw EngineError.invalidArgument("\(instruction) failed: forbidden path outside the build context: \(pattern)")
        }
        if relative == "." {
            return ["/"]
        }
        if !relative.contains(where: { "*?[".contains($0) }) {
            guard FileManager.default.fileExists(atPath: FSInventory.hostURL(root: root, path: relative).path) else {
                throw EngineError.invalidArgument(
                    "\(instruction) failed: file not found in build context or excluded by .dockerignore: \(pattern)"
                )
            }
            return ["/" + relative]
        }
        guard let regex = try? NSRegularExpression(pattern: "^\(DockerIgnore.regexBody(relative))$") else {
            throw EngineError.invalidArgument("\(instruction) failed: invalid pattern \(pattern)")
        }
        var matches: [String] = []
        for (path, _) in FSInventory.walkDirectory(root) {
            let candidate = String(path.dropFirst())
            if regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                matches.append(path)
            }
        }
        guard !matches.isEmpty else {
            throw EngineError.invalidArgument(
                "\(instruction) failed: no source files were specified, or they were excluded by .dockerignore: \(pattern)"
            )
        }
        return matches.sorted()
    }

    private static func isArchive(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst"].contains {
            lower.hasSuffix($0)
        }
    }

    private static func place(_ source: URL, at target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
    }

    /// Copies a tree into a destination that may already hold entries from an earlier source.
    private static func mergeCopy(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true, values?.isDirectory == true else {
            try place(source, at: target)
            return
        }
        if !fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        if let mode = (try? fm.attributesOfItem(atPath: source.path))?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
        for child in try ArchivePath.entries(in: source) {
            try mergeCopy(from: child, to: target.appendingPathComponent(child.lastPathComponent))
        }
    }

    private static func download(_ url: URL, to target: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EngineError.invalidArgument("ADD failed to fetch \(url.absoluteString): HTTP \(http.statusCode)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    private static func applyMode(_ mode: UInt16, under root: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        while let url = enumerator.nextObject() as? URL {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        }
    }
}
