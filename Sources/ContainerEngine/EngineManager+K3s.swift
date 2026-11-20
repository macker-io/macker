import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Darwin
import Foundation
import SystemPackage

public struct K3sStatus: Codable, Sendable {
    public let state: String
    public let endpoint: String?
    public let detail: String?
}

extension EngineManager {
    private static let k3sName = "macker-k3s"
    private static let k3sImage = "docker.io/rancher/k3s:v1.34.3-k3s1"
    private static let k3sMount = "/k3s-state"

    static func isK3sContainer(_ container: EngineContainer) -> Bool {
        container.isSystem && container.name == k3sName
    }

    private var k3sID: String? {
        containers.values.first(where: Self.isK3sContainer)?.id
    }

    private var k3sDisk: URL { imageStore.path.appendingPathComponent("k3s/state.ext4") }

    public func startK3s(wait: Bool = false) async throws -> EnginePortBinding {
        // Fail before pulling the image or allocating the state disk.
        _ = try RuntimeAssets.k3sKernel()
        guard !k3sChanging else { throw EngineError.conflict("K3s lifecycle change in progress") }
        k3sChanging = true
        defer { k3sChanging = false }
        let id: String
        if let existing = k3sID {
            id = existing
        } else {
            if (try? await inspectImage(name: Self.k3sImage)) == nil {
                for try await _ in pullImage(name: Self.k3sImage) {}
            }
            let disk = k3sDisk
            if !FileManager.default.fileExists(atPath: disk.path) {
                try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
                let partial = disk.appendingPathExtension(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: partial) }
                let formatter = try EXT4.Formatter(FilePath(partial.path), minDiskSize: 16 * 1024 * 1024 * 1024, journal: .default)
                try formatter.close()
                try FileManager.default.moveItem(at: partial, to: disk)
            }
            var spec = EngineContainerCreateSpec(
                name: Self.k3sName, image: Self.k3sImage,
                cmd: [Self.k3sLaunchScript],
                entrypoint: ["/bin/sh", "-ec"],
                memory: 4 * 1024 * 1024 * 1024, nanoCpus: 2_000_000_000,
                portBindings: [.init(hostIP: "127.0.0.1", hostPort: 0, containerPort: 6443)],
                privileged: true
            )
            spec.system = true
            let mount = EngineMount(type: EngineMount.blockType, name: "", source: disk.path, destination: Self.k3sMount, rw: true)
            id = try await createContainer(spec, systemMounts: [mount]).id
        }
        _ = try await startContainer(id)
        guard let binding = containers[id]?.portBindings.first,
              binding.hostIP == "127.0.0.1", binding.hostPort > 0
        else { throw EngineError.runtimeUnavailable("K3s loopback port was not published") }
        if wait {
            let deadline = ContinuousClock.now + .seconds(120)
            while ContinuousClock.now < deadline {
                guard containers[id]?.state == "running", vms[id] != nil else {
                    throw EngineError.runtimeUnavailable("K3s MicroVM exited before the node was Ready (exit \(containers[id]?.exitCode ?? -1))")
                }
                if await k3sReady(id) { return binding }
                try await Task.sleep(for: .seconds(2))
            }
            throw EngineError.runtimeUnavailable("K3s did not reach Ready in 120 seconds; the MicroVM was not stopped")
        }
        return binding
    }

    private func k3sReady(_ id: String) async -> Bool {
        let result = try? await runGuest(id, command: [
            "/bin/sh", "-ec",
            "/bin/kubectl --request-timeout=2s get --raw /readyz >/dev/null; " +
            "exec /bin/kubectl --request-timeout=2s get nodes -o 'jsonpath={.items[0].status.conditions[?(@.type==\"Ready\")].status}'",
        ])
        return result?.code == 0 && result?.stdout == "True" && containers[id]?.state == "running" && vms[id] != nil
    }

    public func k3sStatus() async -> K3sStatus {
        guard let id = k3sID, let record = containers[id] else {
            let hasDisk = FileManager.default.fileExists(atPath: k3sDisk.path)
            return .init(state: k3sChanging ? "busy" : (hasDisk ? "stopped" : "not-created"), endpoint: nil, detail: nil)
        }
        guard record.state == "running", vms[id] != nil else {
            let failed = record.state == "exited" && record.exitCode != 0
            return .init(
                state: k3sChanging ? "busy" : "stopped", endpoint: nil,
                detail: failed ? "Last VM exit code: \(record.exitCode)" : nil
            )
        }
        let ready = await k3sReady(id)
        guard let current = containers[id], current.state == "running", vms[id] != nil else {
            return .init(state: "stopped", endpoint: nil, detail: nil)
        }
        let endpoint = current.portBindings.first.map { "https://\($0.joinedHostPort)" }
        return .init(state: ready ? "ready" : "initializing", endpoint: endpoint, detail: nil)
    }

    public func resetK3s() async throws {
        guard !k3sChanging else { throw EngineError.conflict("K3s lifecycle change or image sync in progress") }
        if let id = k3sID, containers[id]?.isActive == true || vms[id] != nil || startTasks[id] != nil {
            throw EngineError.conflict("stop K3s before resetting the cluster")
        }
        k3sChanging = true
        defer { k3sChanging = false }
        let disk = k3sDisk
        // Never follow a symlink outside the daemon's cluster state directory.
        let directory = disk.deletingLastPathComponent()
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) != nil {
            throw EngineError.conflict("K3s state directory is a symbolic link")
        }
        if let id = k3sID {
            try await deleteContainer(id, force: false, removeAnonymousVolumes: false)
        }
        // Unlink a file only; never recursively delete a directory at this path.
        if unlink(disk.path) != 0, errno != ENOENT {
            throw EngineError.runtimeUnavailable("cannot remove K3s state disk: \(String(cString: strerror(errno)))")
        }
    }

    public func stopK3s() async throws {
        guard !k3sChanging else { throw EngineError.conflict("K3s lifecycle change in progress") }
        guard let id = k3sID else { return }
        k3sChanging = true
        defer { k3sChanging = false }
        _ = try await stopContainer(id, timeoutSeconds: 20)
    }

    public func readK3sKubeconfig() async throws -> String {
        guard let id = k3sID, let record = containers[id], record.state == "running",
              let port = record.portBindings.first, port.hostIP == "127.0.0.1", port.hostPort > 0
        else { throw EngineError.conflict("K3s is not running") }
        let result = try await runGuest(id, command: ["/bin/cat", "/etc/rancher/k3s/k3s.yaml"])
        let guestServer = "    server: https://127.0.0.1:6443"
        guard result.code == 0, result.stdout.split(separator: "\n").contains(Substring(guestServer)) else {
            throw EngineError.runtimeUnavailable("K3s kubeconfig is not ready")
        }
        return result.stdout.replacingOccurrences(of: guestServer, with: "    server: https://\(port.joinedHostPort)")
    }

    /// Build sync uses the exact build digest; manual sync resolves the named local tag.
    public func syncK3sImage(digest: String? = nil, tags: [String]) async throws {
        guard !tags.isEmpty else { throw EngineError.invalidArgument("K3s image sync requires at least one tag") }
        guard !k3sChanging else { throw EngineError.conflict("K3s lifecycle change or image sync in progress") }
        guard let id = k3sID, containers[id]?.state == "running", vms[id] != nil else {
            throw EngineError.conflict("K3s is not running")
        }
        k3sChanging = true
        defer { k3sChanging = false }

        let references = try Set(tags.map { tag in
            let reference = try Self.normalizedReference(name: tag, tag: "latest")
            guard !reference.contains("@") else { throw EngineError.invalidReference("K3s sync requires named tags") }
            let tagged = try Reference.parse(reference)
            guard tagged.tag != nil else { throw EngineError.invalidReference("K3s sync requires named tags") }
            return reference
        }).sorted()
        let source: String
        if let digest {
            let image = try await resolveImage(digest)
            guard image.digest == digest, image.reference == digest else {
                throw EngineError.invalidArgument("expected a local build image ID")
            }
            source = digest
        } else {
            guard references.count == 1, let reference = references.first else {
                throw EngineError.invalidArgument("sync one existing local tag per request")
            }
            // An exact tag lookup avoids matching a different reference or pulling remotely.
            source = try await imageStore.get(reference: reference).reference
        }

        try await withScratch("macker-k3s-image") { work in
            let layout = work.appendingPathComponent("oci", isDirectory: true)
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
            try await imageStore.save(references: [source], out: layout, platform: Self.buildPlatform(nil))
            let indexURL = layout.appendingPathComponent("index.json")
            var index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
            guard index.manifests.count == 1, let descriptor = index.manifests.first else {
                throw EngineError.exportFailed("K3s sync expected one exported image")
            }
            index.manifests = references.map { reference in
                var named = descriptor
                named.annotations = [
                    "io.containerd.image.name": reference,
                    "org.opencontainers.image.ref.name": reference,
                ]
                return named
            }
            try JSONEncoder().encode(index).write(to: indexURL)
            let archive = work.appendingPathComponent("image.tar")
            try Self.runTar(["-C", layout.path, "-cf", archive.path, "oci-layout", "index.json", "blobs"])

            let input = try K3sArchiveInput(archive)
            let result = try await runGuest(id, command: [
                "/bin/sh", "-c",
                "exec /bin/ctr --address /run/k3s/containerd/containerd.sock --namespace k8s.io images import --platform linux/arm64 - 2>&1",
            ], timeoutSeconds: 300, stdin: input)
            try await input.checkRead()
            guard result.code == 0 else {
                let detail = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000)
                throw EngineError.loadFailed("K3s containerd import exited with status \(result.code): \(detail)")
            }
        }
    }

    private static let k3sLaunchScript = """
        for name in iptables ip6tables; do
          for suffix in '' -save -restore; do
            ln -sf "$name-legacy$suffix" "/bin/aux/$name$suffix"
          done
        done
        exec /bin/k3s server --disable=traefik --disable=servicelb --disable-network-policy \\
          --snapshotter=overlayfs --flannel-backend=host-gw --data-dir=/k3s-state/server \\
          --kubelet-arg=root-dir=/k3s-state/kubelet --tls-san=127.0.0.1
        """
}

/// Stream the tar in bounded chunks; the guest needs no temporary archive.
private actor K3sArchiveInput: ReaderStream {
    private let file: FileHandle
    private var failure: (any Error)?

    init(_ path: URL) throws {
        file = try FileHandle(forReadingFrom: path)
    }

    nonisolated func stream() -> AsyncStream<Data> {
        AsyncStream(unfolding: { await self.read() })
    }

    private func read() -> Data? {
        do {
            guard let data = try file.read(upToCount: 256 * 1024), !data.isEmpty else { return nil }
            return data
        } catch {
            failure = error
            return nil
        }
    }

    func checkRead() throws {
        if let failure { throw failure }
    }
}
