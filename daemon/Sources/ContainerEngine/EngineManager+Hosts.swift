import Containerization
import Foundation

extension EngineManager {
    func hostsFile(for record: EngineContainer) -> Hosts {
        Self.hostsFile(for: record, peers: Array(containers.values))
    }

    /// Peer names for `/etc/hosts`. Stopped containers are omitted so their last IPs cannot collide.
    static func hostsFile(for record: EngineContainer, peers: [EngineContainer]) -> Hosts {
        var hosts = Hosts.default
        let networkIDs = record.networkIDs
        var byIP: [String: [String]] = [:]

        func add(_ ip: String, _ name: String) {
            let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !ip.isEmpty, !trimmed.isEmpty else { return }
            var names = byIP[ip] ?? []
            if !names.contains(trimmed) {
                names.append(trimmed)
            }
            byIP[ip] = names
        }

        for peer in peers where peer.id == record.id || peer.isActive {
            for endpoint in peer.endpoints where networkIDs.contains(endpoint.networkID) && !endpoint.ipv4Address.isEmpty {
                add(endpoint.ipv4Address, peer.name)
                add(endpoint.ipv4Address, peer.hostname)
                add(endpoint.ipv4Address, String(peer.id.prefix(12)))
                for alias in endpoint.aliases {
                    add(endpoint.ipv4Address, alias)
                }
            }
        }

        for (ip, names) in byIP.sorted(by: { $0.key < $1.key }) {
            hosts.entries.append(.init(ipAddress: ip, hostnames: names))
        }
        return hosts
    }

    func refreshPeerHosts(networkIDs: Set<String>) async {
        guard !networkIDs.isEmpty else { return }
        let members = containers.values.filter { container in
            container.state == "running" && !container.networkIDs.isDisjoint(with: networkIDs)
        }
        for container in members {
            await writeGuestHosts(container)
        }
    }

    private func writeGuestHosts(_ record: EngineContainer) async {
        guard record.state == "running" else { return }
        let hosts = hostsFile(for: record)
        do {
            try await withGuestAgent(record.id) { agent in
                try await agent.configureHosts(config: hosts, location: Self.guestRootfsPath(record.id))
            }
        } catch {
            await copyGuestHosts(record.id, hosts: hosts)
        }
    }

    private func copyGuestHosts(_ id: String, hosts: Hosts) async {
        guard let linux = vms[id] else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("macker-hosts-\(id)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? hosts.hostsFile.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return }
        try? await linux.copyIn(from: tmp, to: URL(filePath: "/etc/hosts"), mode: 0o644)
    }
}
