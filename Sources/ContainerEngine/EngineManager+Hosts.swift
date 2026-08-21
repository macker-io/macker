import Containerization
import Foundation

extension EngineManager {
    func hostsFile(for record: EngineContainer) -> Hosts {
        Self.hostsFile(for: record, peers: Array(containers.values))
    }

    /// Peers stay out of `/etc/hosts` (they resolve through gateway DNS, so `network connect`
    /// / `disconnect` does not rewrite the guest). The container's own names must be here:
    /// glibc `getaddrinfo(hostname)` otherwise waits ~20s on AAAA, which is why Debian images
    /// such as nginx start slowly while Alpine does not.
    static func hostsFile(for record: EngineContainer, peers: [EngineContainer]) -> Hosts {
        var hosts = Hosts.default
        let ip = record.endpoints.first { !$0.ipv4Address.isEmpty }?.ipv4Address ?? "127.0.0.1"
        var names: [String] = []
        for raw in [record.hostname, record.name, String(record.id.prefix(12))] {
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
        }
        if !names.isEmpty {
            hosts.entries.append(Hosts.Entry(ipAddress: ip, hostnames: names))
        }
        for extra in record.run.extraHosts {
            guard let parsed = try? EngineExtraHost.parse(extra) else { continue }
            hosts.entries.append(Hosts.Entry(ipAddress: parsed.ip, hostnames: [parsed.host]))
        }
        return hosts
    }
}
