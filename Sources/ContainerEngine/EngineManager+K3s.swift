import ContainerizationEXT4
import Foundation
import SystemPackage

extension EngineManager {
    private static let k3sName = "macker-k3s"
    private static let k3sImage = "docker.io/rancher/k3s:v1.34.3-k3s1"
    private static let k3sMount = "/k3s-state"

    private var k3sID: String? {
        containers.values.first { $0.isSystem && $0.name == Self.k3sName }?.id
    }

    public func startK3s() async throws -> EnginePortBinding {
        guard ProcessInfo.processInfo.environment["MACKER_EXPERIMENTAL_K3S"] == "1",
              !(ProcessInfo.processInfo.environment["MACKER_KERNEL"] ?? "").isEmpty
        else {
            throw EngineError.runtimeUnavailable("K3s requires MACKER_EXPERIMENTAL_K3S=1 and a compatible MACKER_KERNEL on the daemon")
        }
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
            let disk = imageStore.path.appendingPathComponent("k3s/state.ext4")
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
        return binding
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
