import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Darwin
import Foundation
import SystemPackage

/// The daemon-owned BuildKit backend.
///
/// One hidden, privileged MicroVM runs the stock `moby/buildkit` image. Privilege is confined
/// to that VM's own kernel. Its state lives on an ext4 disk image, because overlayfs (BuildKit's
/// snapshotter) cannot use a virtiofs share as an upper layer. Callers get raw byte streams to
/// `buildkitd` (`buildctl dial-stdio`) and import exported images back into the local store.
extension EngineManager {
    static let buildKitContainerName = "macker-buildkit"
    static let buildKitImage = "docker.io/moby/buildkit:buildx-stable-1"
    /// Sparse; only written blocks use host disk.
    static let buildKitStateBytes: UInt64 = 64 * 1024 * 1024 * 1024
    static let buildKitStateMount = "/var/lib/buildkit"

    /// Opens a byte stream to `buildkitd`, booting the builder VM on first use. The returned
    /// descriptor is one end of a socket pair; closing it ends the stream.
    public func dialBuildKit() async throws -> Int32 {
        let id = try await ensureBuildKit()
        return try await execSocket(id, command: ["buildctl", "dial-stdio"])
    }

    /// Copies an image that `buildkitd` exported into its content store (the `image` exporter)
    /// into the local image store, tags it with `names`, and returns the local image ID.
    public func importBuildKitImage(digest: String, names: [String]) async throws -> String {
        guard let id = buildKitContainerID(), vms[id] != nil else {
            throw EngineError.runtimeUnavailable("the BuildKit builder is not running")
        }
        let contentRoot = try await buildKitContentRoot(id)
        return try await withScratch("macker-bkimport") { work in
            let blobs = work.appendingPathComponent("blobs", isDirectory: true)
            try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
            let root = try await copyBuildKitBlob(id, contentRoot: contentRoot, digest: digest, into: blobs)
            let rootJSON = try Data(contentsOf: root)
            let rootMediaType = Self.mediaType(of: rootJSON)
            var files: [URL] = [root]
            // index → manifests → (config, layers); configs and layers are leaves.
            let manifests: [Data]
            if Self.isIndex(rootMediaType) {
                var loaded: [Data] = []
                for child in try Self.childDigests(of: rootJSON) {
                    let file = try await copyBuildKitBlob(id, contentRoot: contentRoot, digest: child, into: blobs)
                    files.append(file)
                    loaded.append(try Data(contentsOf: file))
                }
                manifests = loaded
            } else if Self.isManifest(rootMediaType) {
                manifests = [rootJSON]
            } else {
                throw EngineError.exportFailed("BuildKit exported an unknown object (\(rootMediaType)) for \(digest)")
            }
            var platform: Platform?
            for manifest in manifests {
                let children = try Self.childDigests(of: manifest)
                for (index, child) in children.enumerated() {
                    let file = try await copyBuildKitBlob(id, contentRoot: contentRoot, digest: child, into: blobs)
                    files.append(file)
                    if index == 0, platform == nil,
                        let config = try? JSONDecoder().decode(ImageConfigPlatform.self, from: Data(contentsOf: file)),
                        let architecture = config.architecture, let os = config.os
                    {
                        platform = Platform(arch: architecture, os: os, variant: config.variant)
                    }
                }
            }

            let contentStore = try LocalContentStore(path: imageStore.path.appendingPathComponent("content"))
            let sources = files
            let box = DescriptorBox()
            let rootSize = Int64(rootJSON.count)
            let wrapPlatform = platform
            try await contentStore.ingest { dir in
                let writer = try ContentWriter(for: dir)
                for file in sources {
                    _ = try writer.create(from: file)
                }
                let rootDescriptor = Descriptor(mediaType: rootMediaType, digest: digest, size: rootSize)
                if Self.isIndex(rootMediaType) {
                    box.set(rootDescriptor)
                    return
                }
                // The local store addresses images by index; wrap a single manifest.
                var manifest = rootDescriptor
                manifest.platform = wrapPlatform
                let index = try writer.create(from: Index(manifests: [manifest]))
                box.set(Descriptor(mediaType: MediaTypes.index, digest: index.digest.digestString, size: index.size))
            }
            guard let descriptor = box.get() else {
                throw EngineError.exportFailed("failed to register the built image")
            }
            let image = try await adoptImage(descriptor)
            for name in names where !name.isEmpty {
                let reference = try Self.normalizedReference(name: name, tag: "latest")
                _ = try await imageStore.tag(existing: image.reference, new: reference)
                await publishImage(action: "tag", digest: image.digest, name: reference)
            }
            return image.digest
        }
    }

    // MARK: - Builder VM

    private func buildKitContainerID() -> String? {
        containers.values.first { $0.isSystem && $0.name == Self.buildKitContainerName }?.id
    }

    /// Boots (or reuses) the builder. Concurrent callers share one boot.
    private func ensureBuildKit() async throws -> String {
        if let id = buildKitContainerID(), containers[id]?.state == "running", vms[id] != nil {
            return id
        }
        if let pending = buildKitBoot {
            return try await pending.value
        }
        let task = Task { try await self.bootBuildKit() }
        buildKitBoot = task
        defer { buildKitBoot = nil }
        return try await task.value
    }

    private func bootBuildKit() async throws -> String {
        let id: String
        if let existing = buildKitContainerID() {
            id = existing
        } else {
            id = try await createBuildKitContainer()
        }
        if containers[id]?.state != "running" {
            _ = try await startContainer(id)
        }
        try await waitForBuildKit(id)
        return id
    }

    private func createBuildKitContainer() async throws -> String {
        if (try? await inspectImage(name: Self.buildKitImage)) == nil {
            for try await _ in pullImage(name: Self.buildKitImage) {}
        }
        let disk = imageStore.path
            .appendingPathComponent("buildkit", isDirectory: true)
            .appendingPathComponent("state.ext4")
        if !FileManager.default.fileExists(atPath: disk.path) {
            try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = disk.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: partial)
            let formatter = try EXT4.Formatter(
                FilePath(partial.path),
                minDiskSize: Self.buildKitStateBytes,
                journal: .default
            )
            try formatter.close()
            try FileManager.default.moveItem(at: partial, to: disk)
        }
        let cores = ProcessInfo.processInfo.processorCount
        var spec = EngineContainerCreateSpec(
            name: Self.buildKitContainerName,
            image: Self.buildKitImage,
            labels: ["io.macker.system": "buildkit"],
            memory: 4 * 1024 * 1024 * 1024,
            nanoCpus: Int64(max(2, min(cores / 2, 8))) * 1_000_000_000,
            privileged: true,
            useInit: true
        )
        spec.system = true
        let created = try await createContainer(spec)
        guard var record = containers[created.id] else {
            throw EngineError.runtimeUnavailable("failed to create the BuildKit builder")
        }
        record.mounts.append(
            EngineMount(type: EngineMount.blockType, name: "", source: disk.path, destination: Self.buildKitStateMount, rw: true)
        )
        saveContainer(record)
        return created.id
    }

    /// `buildctl debug workers` succeeds once `buildkitd` serves its socket. Bounded readiness
    /// probe (the process is up; its socket appears shortly after).
    private func waitForBuildKit(_ id: String) async throws {
        var delay = 100
        var lastError = ""
        for _ in 0..<40 {
            guard containers[id]?.state == "running" else {
                let replay = try? await tailContainerLogs(id, count: 5, follow: false, stdout: true, stderr: true, since: nil, until: nil)
                let tail = replay?.history.map { String(decoding: $0.data, as: UTF8.self) }.joined() ?? ""
                throw EngineError.runtimeUnavailable("buildkitd exited during startup: \(tail)")
            }
            if let result = try? await runGuest(id, command: ["buildctl", "debug", "workers"]), result.code == 0 {
                return
            } else {
                lastError = "buildctl debug workers failed"
            }
            try await Task.sleep(for: .milliseconds(delay))
            delay = min(delay * 2, 1000)
        }
        throw EngineError.runtimeUnavailable("buildkitd did not become ready: \(lastError)")
    }

    private func buildKitContentRoot(_ id: String) async throws -> String {
        let result = try await runGuest(
            id,
            command: ["sh", "-c", "ls -d \(Self.buildKitStateMount)/*/content 2>/dev/null | head -1"]
        )
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw EngineError.runtimeUnavailable("BuildKit content store not found")
        }
        return path
    }

    private func copyBuildKitBlob(_ id: String, contentRoot: String, digest: String, into dir: URL) async throws -> URL {
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1].allSatisfy(\.isHexDigit) else {
            throw EngineError.invalidArgument("invalid digest \(digest)")
        }
        let destination = dir.appendingPathComponent(parts[1])
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        // The state disk is mounted in the container's mount namespace only, so read the
        // blob through the container rather than the VM-level copy channel.
        let fd = try await execSocket(id, command: ["cat", "\(contentRoot)/blobs/\(parts[0])/\(parts[1])"])
        try await Self.drain(fd: fd, to: destination)
        let actual = try TarArchive.sha256(of: destination)
        guard parts[0] != "sha256" || actual == digest || "sha256:" + actual == digest else {
            try? FileManager.default.removeItem(at: destination)
            throw EngineError.exportFailed("BuildKit blob \(digest) is missing or corrupt")
        }
        return destination
    }

    /// Reads `fd` to EOF into `file`, then closes `fd`.
    static func drain(fd: Int32, to file: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                defer { Darwin.close(fd) }
                FileManager.default.createFile(atPath: file.path, contents: nil)
                guard let out = try? FileHandle(forWritingTo: file) else {
                    continuation.resume(throwing: EngineError.exportFailed("cannot write \(file.path)"))
                    return
                }
                defer { try? out.close() }
                var buffer = [UInt8](repeating: 0, count: 1 << 20)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n == 0 { break }
                    if n < 0 {
                        if errno == EINTR { continue }
                        continuation.resume(throwing: EngineError.exportFailed("read failed: \(String(cString: strerror(errno)))"))
                        return
                    }
                    out.write(Data(buffer[0..<n]))
                }
                continuation.resume()
            }
        }
    }

    private struct ImageConfigPlatform: Decodable {
        let architecture: String?
        let os: String?
        let variant: String?
    }

    private struct MediaTypeProbe: Decodable {
        let mediaType: String?
        let manifests: [Child]?
        let config: Child?
        let layers: [Child]?
        struct Child: Decodable {
            let digest: String
        }
    }

    static func mediaType(of json: Data) -> String {
        guard let probe = try? JSONDecoder().decode(MediaTypeProbe.self, from: json) else {
            return ""
        }
        if let type = probe.mediaType, !type.isEmpty {
            return type
        }
        if probe.manifests != nil { return MediaTypes.index }
        if probe.config != nil { return MediaTypes.imageManifest }
        return ""
    }

    static func isIndex(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.index || mediaType == MediaTypes.dockerManifestList
    }

    static func isManifest(_ mediaType: String) -> Bool {
        mediaType == MediaTypes.imageManifest || mediaType == MediaTypes.dockerManifest
    }

    /// Direct children: an index's manifests, or a manifest's config and layers.
    static func childDigests(of json: Data) throws -> [String] {
        let probe = try JSONDecoder().decode(MediaTypeProbe.self, from: json)
        if let manifests = probe.manifests {
            return manifests.map(\.digest)
        }
        return (probe.config.map { [$0.digest] } ?? []) + (probe.layers ?? []).map(\.digest)
    }
}

// MARK: - Byte-stream exec

extension EngineManager {
    /// Starts `command` in running container `id` with stdin/stdout bound to one end of a
    /// socket pair and returns the other end. Reads and writes block on the socket, so a slow
    /// peer back-pressures the guest instead of buffering without bound.
    func execSocket(_ id: String, command: [String]) async throws -> Int32 {
        guard let linux = vms[id], let container = containers[id] else {
            throw EngineError.conflict("container \(id) is not running")
        }
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw EngineError.runtimeUnavailable("socketpair failed: \(String(cString: strerror(errno)))")
        }
        for fd in fds {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let local = SocketStdio(fd: fds[0])
        let stderr = ProcessLogSink { _ in }
        let processID = Self.makeContainerID()
        let process: LinuxProcess
        do {
            process = try await linux.exec(processID) { config in
                config.arguments = command
                config.environmentVariables = Self.mergedEnvironment(container.env, tty: false)
                config.terminal = false
                try Self.applyProcessSecurity(&config, run: container.run)
                config.stdin = local
                config.stdout = local
                config.stderr = stderr
            }
            try await process.start()
        } catch {
            local.closeAll()
            close(fds[1])
            throw EngineError.runtimeUnavailable(Self.describeExecFailure(error, command: command))
        }
        Task.detached {
            _ = try? await process.wait()
            try? await process.delete()
            local.closeAll()
        }
        return fds[1]
    }
}

/// Process stdin/stdout over one socket. stdin is pulled on demand (one read per request
/// from the relay), stdout writes block until the peer drains.
final class SocketStdio: ReaderStream, Writer, @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func stream() -> AsyncStream<Data> {
        let fd = self.fd
        return AsyncStream(unfolding: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global().async {
                    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                    while true {
                        let n = read(fd, &buffer, buffer.count)
                        if n > 0 {
                            continuation.resume(returning: Data(buffer[0..<n]))
                            return
                        }
                        if n < 0, errno == EINTR { continue }
                        continuation.resume(returning: nil)
                        return
                    }
                }
            }
        })
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, base, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw EngineError.runtimeUnavailable("stream closed: \(String(cString: strerror(errno)))")
                }
                remaining -= n
                base = base.advanced(by: n)
            }
        }
    }

    /// End of guest stdout: half-close so the peer sees EOF while it may still send.
    func close() throws {
        shutdown(fd, SHUT_WR)
    }

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
