import Foundation

enum ResourceKind: String, CaseIterable, Identifiable {
    case containers, images, networks, volumes

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var columnTitle: String { self == .images ? "Repository / Tag" : "Name" }
    var secondColumn: String {
        switch self {
        case .containers: "Image"
        case .images: "Size"
        case .networks, .volumes: "Driver"
        }
    }

    var thirdColumn: String {
        switch self {
        case .containers: "Status"
        case .images: "Image ID"
        case .networks: "Subnets"
        case .volumes: "Mount Point"
        }
    }

    var symbol: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack"
        case .networks: "network"
        case .volumes: "externaldrive"
        }
    }
}

struct ResourceRow: Identifiable {
    let id: String
    let name: String
    let secondary: String
    let tertiary: String
    let details: [Detail]
    var isRunning = false

    struct Detail: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [name, secondary, tertiary, id].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

nonisolated struct DaemonSnapshot: Sendable {
    let version: String
    let containers: [Container]
    let images: [Image]
    let networks: [Network]
    let volumes: [Volume]

    struct Container: Decodable, Sendable {
        let Id: String
        let Names: [String]
        let Image: String
        let ImageID: String?
        let State: String
        let Status: String
        let Ports: [Port]?

        struct Port: Decodable, Sendable {
            let IP: String?
            let PrivatePort: Int
            let PublicPort: Int?
            let `Type`: String
        }
    }

    struct Image: Decodable, Sendable {
        let Id: String
        let RepoTags: [String]?
        let Size: Int64
        let Created: Int64?
        let Containers: Int?
        let Platform: String?
    }

    struct Network: Decodable, Sendable {
        let Id: String
        let Name: String
        let Driver: String
        let EnableIPv6: Bool
        let Internal: Bool
        let IPAM: IPAMConfig

        struct IPAMConfig: Decodable, Sendable {
            let Config: [Subnet]?
        }

        struct Subnet: Decodable, Sendable {
            let Subnet: String
            let Gateway: String
        }
    }

    struct Volume: Decodable, Sendable {
        let Name: String
        let Driver: String
        let Mountpoint: String
        let Scope: String
    }
}

extension DaemonSnapshot {
    @MainActor func rows(for kind: ResourceKind) -> [ResourceRow] {
        switch kind {
        case .containers:
            containers.map { container in
                let name = container.Names.first?.trimmingPrefix("/") ?? container.Id.prefix(12)
                let ports = (container.Ports ?? []).compactMap { port -> String? in
                    guard let published = port.PublicPort, published > 0 else { return nil }
                    let ip = port.IP ?? "0.0.0.0"
                    let host = ip.contains(":") ? "[\(ip)]" : ip
                    return "\(host):\(published) → \(port.PrivatePort)/\(port.Type)"
                }
                return ResourceRow(
                    id: container.Id, name: String(name), secondary: container.Image, tertiary: container.Status,
                    details: [
                        .init(label: "Container ID", value: container.Id),
                        .init(label: "Image", value: container.Image),
                        .init(label: "Status", value: container.Status),
                        .init(label: "Published Ports", value: ports.isEmpty ? "None" : ports.joined(separator: "\n")),
                    ], isRunning: container.State == "running"
                )
            }
        case .images:
            [] // Images uses its own table model.
        case .networks:
            networks.map { network in
                let config = network.IPAM.Config ?? []
                let subnets = config.map(\.Subnet).filter { !$0.isEmpty }
                let gateways = config.map(\.Gateway).filter { !$0.isEmpty }
                return ResourceRow(
                    id: network.Id, name: network.Name, secondary: network.Driver, tertiary: subnets.joined(separator: ", "),
                    details: [
                        .init(label: "Network ID", value: network.Id),
                        .init(label: "Driver", value: network.Driver == "host" ? "host (vmnet NAT)" : network.Driver),
                        .init(label: "Subnets", value: subnets.isEmpty ? "None" : subnets.joined(separator: "\n")),
                        .init(label: "Gateways", value: gateways.isEmpty ? "None" : gateways.joined(separator: "\n")),
                        .init(label: "IPv6", value: network.EnableIPv6 ? "Enabled" : "Disabled"),
                        .init(label: "Internal", value: network.Internal ? "Yes" : "No"),
                    ]
                )
            }
        case .volumes:
            volumes.map { volume in
                ResourceRow(
                    id: volume.Name, name: volume.Name, secondary: volume.Driver, tertiary: volume.Mountpoint,
                    details: [
                        .init(label: "Driver", value: volume.Driver),
                        .init(label: "Scope", value: volume.Scope),
                        .init(label: "Mount Point", value: volume.Mountpoint),
                    ]
                )
            }
        }
    }
}
