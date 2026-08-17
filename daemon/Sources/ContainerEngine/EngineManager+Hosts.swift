import Containerization
import Foundation

extension EngineManager {
    func hostsFile(for record: EngineContainer) -> Hosts {
        Self.hostsFile(for: record, peers: Array(containers.values))
    }

    /// `/etc/hosts` stays localhost-only: peers resolve through the gateway DNS instead, so
    /// `network connect` / `disconnect` never has to rewrite files inside running guests.
    static func hostsFile(for record: EngineContainer, peers: [EngineContainer]) -> Hosts {
        Hosts.default
    }
}
