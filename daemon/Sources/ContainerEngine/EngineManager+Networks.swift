import Containerization
import ContainerizationExtras
import Foundation

/// Docker-shaped networks on MicroVMs.
/// Bridge: one virtio-net to ``NetworkGateway`` (L3, DNS, NAT; host routes via utun + helper).
/// Host: per-network vmnet NAT. None: no NIC. macvlan/sidecar stay unimplemented.
extension EngineManager {
    static let builtinBridgeName = "bridge"
    static let builtinHostName = "host"
    static let builtinNoneName = "none"
    static let defaultBridgeSubnet = "172.17.0.0/16"
    static let defaultHostSubnet = "172.19.0.0/16"

    public func listNetworks(filters: [String: [String]] = [:]) -> [EngineNetworkInspect] {
        var items = networks.values.map(inspectPayload)
        if let names = filters["name"], !names.isEmpty {
            items = items.filter { item in names.contains { item.network.name.contains($0) } }
        }
        if let ids = filters["id"], !ids.isEmpty {
            items = items.filter { item in ids.contains { item.network.id.hasPrefix($0) || item.network.id == $0 } }
        }
        if let drivers = filters["driver"], !drivers.isEmpty {
            items = items.filter { drivers.contains($0.network.driver) }
        }
        if let labels = filters["label"], !labels.isEmpty {
            items = items.filter { FilterMatch.labels($0.network.labels, specs: labels) }
        }
        return items.sorted { $0.network.name < $1.network.name }
    }

    public func inspectNetwork(_ idOrName: String) throws -> EngineNetworkInspect {
        inspectPayload(try resolveNetwork(idOrName))
    }

    public func createNetwork(_ spec: EngineNetworkCreateSpec) async throws -> EngineNetworkInspect {
        await prepareGateway()
        let driver = spec.driver.isEmpty ? "bridge" : spec.driver
        guard driver == "bridge" else {
            throw EngineError.invalidArgument("network driver \"\(driver)\" is not supported")
        }

        let raw = spec.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name: String
        if raw.isEmpty {
            name = "macker-\(String(Self.makeContainerID().prefix(12)))"
        } else {
            guard Self.isValidNetworkName(raw) else {
                throw EngineError.invalidArgument("invalid network name: \(raw)")
            }
            name = raw
        }
        if networks.values.contains(where: { $0.name == name }) {
            throw EngineError.conflict("network with name \(name) already exists")
        }

        let subnet = try spec.subnet.map { try Self.normalizedSubnet($0) } ?? nextSubnet()
        let gateway = spec.gateway?.isEmpty == false ? spec.gateway! : Self.gateway(for: subnet)
        let network = EngineNetwork(
            id: Self.makeContainerID(),
            name: name,
            driver: driver,
            scope: "local",
            created: Date(),
            labels: spec.labels,
            subnet: subnet,
            gateway: gateway,
            internalNetwork: spec.internalNetwork,
            builtin: false
        )
        try persistNetwork(network)
        networks[network.id] = network
        await networkGateway.registerNetwork(network)
        await publish(
            EngineEvent(type: "network", action: "create", actorID: network.id, attributes: ["name": name, "type": driver])
        )
        return inspectPayload(network)
    }

    public func deleteNetwork(_ idOrName: String) async throws {
        let network = try resolveNetwork(idOrName)
        if network.builtin {
            throw EngineError.conflict("\(network.name) is a pre-defined network and cannot be removed")
        }
        if networkRefCount(network.id) > 0 {
            throw EngineError.conflict("network \(network.name) is in use")
        }
        try removeNetworkFiles(network.id)
        networks[network.id] = nil
        networkDataplane.remove(network.id)
        await networkGateway.unregisterNetwork(network.id)
        await publish(
            EngineEvent(type: "network", action: "destroy", actorID: network.id, attributes: ["name": network.name, "type": network.driver])
        )
    }

    public func pruneNetworks(filters: [String: [String]] = [:]) async throws -> (deleted: [String], spaceReclaimed: Int64) {
        let unused = listNetworks(filters: filters).filter { !$0.network.builtin && $0.containers.isEmpty }
        var deleted: [String] = []
        for item in unused {
            try await deleteNetwork(item.network.id)
            deleted.append(item.network.id)
        }
        return (deleted, 0)
    }

    public func connectNetwork(_ idOrName: String, spec: EngineNetworkConnectSpec) async throws {
        await prepareGateway()
        let network = try resolveNetwork(idOrName)
        var container = try resolveContainer(spec.container)
        try requireUnpaused(container, action: "connect")
        if container.endpoints.contains(where: { $0.networkID == network.id }) {
            throw EngineError.conflict("container \(container.name) is already connected to \(network.name)")
        }
        try validateAttachment(mode: container.networkMode, extra: network)

        var attached = endpoint(for: network, aliases: spec.aliases)
        if container.state == "running" {
            attached = try await attachRunningEndpoint(container, network: network, aliases: spec.aliases)
        }
        if container.networkMode == "none", network.driver != "none" {
            container.endpoints = [attached]
            container.networkMode = network.name
        } else {
            container.endpoints.append(attached)
        }
        saveContainer(container)
        await publish(
            EngineEvent(
                type: "network",
                action: "connect",
                actorID: network.id,
                attributes: ["name": network.name, "container": container.id, "containerName": container.name]
            )
        )
    }

    public func disconnectNetwork(_ idOrName: String, container idOrContainer: String, force: Bool) async throws {
        let network = try resolveNetwork(idOrName)
        var container = try resolveContainer(idOrContainer)
        try requireUnpaused(container, action: "disconnect")
        guard container.endpoints.contains(where: { $0.networkID == network.id }) else {
            if force { return }
            throw EngineError.conflict("container \(container.name) is not connected to \(network.name)")
        }
        if container.state == "running" {
            try await detachRunningEndpoint(container, network: network)
        }
        container.endpoints.removeAll { $0.networkID == network.id }
        if container.endpoints.isEmpty {
            let none = try resolveNetwork(Self.builtinNoneName)
            container.endpoints = [endpoint(for: none, aliases: [])]
            container.networkMode = "none"
        } else if let primary = container.endpoints.first {
            container.networkMode = primary.networkName
        }
        saveContainer(container)
        await publish(
            EngineEvent(
                type: "network",
                action: "disconnect",
                actorID: network.id,
                attributes: ["name": network.name, "container": container.id, "containerName": container.name]
            )
        )
    }

    func attachCreateEndpoints(_ spec: EngineContainerCreateSpec) throws -> (mode: String, endpoints: [EngineEndpoint], warnings: [String]) {
        var warnings: [String] = []
        let mode = normalizedNetworkMode(spec.networkMode)
        if mode.hasPrefix("container:") || mode == "macvlan" || mode == "ipvlan" {
            throw EngineError.notImplemented("network mode \(mode) is not implemented")
        }

        var requested = spec.endpointRequests
        if !requested.contains(where: { $0.network == mode || resolveNetworkName($0.network) == mode }) {
            requested.insert(EngineEndpointRequest(network: mode), at: 0)
        }

        var endpoints: [EngineEndpoint] = []
        for request in requested {
            let network = try resolveNetwork(request.network)
            try validateAttachment(mode: mode, extra: network)
            if !endpoints.contains(where: { $0.networkID == network.id }) {
                endpoints.append(endpoint(for: network, aliases: request.aliases))
            }
        }

        if mode == "host", !spec.portBindings.isEmpty {
            warnings.append("Published ports are discarded when using host network mode; ExposedPorts are mapped 1:1 on the Mac")
        }
        if mode == "none", !spec.portBindings.isEmpty {
            warnings.append("Published ports are discarded when using none network mode")
        }
        return (mode, endpoints, warnings)
    }

    func allocateInterfaces(for record: inout EngineContainer) async throws -> [any Interface] {
        await prepareGateway()
        var interfaces: [any Interface] = []
        var openedBridge = false
        for index in record.endpoints.indices {
            let network = try resolveNetwork(record.endpoints[index].networkID)
            _ = try NetworkAttachmentFactory.make(driver: network.driver)
            switch network.driver {
            case "none":
                continue
            case "host":
                let allocated = try allocateInterface(
                    network: network,
                    containerID: record.id,
                    secondary: !interfaces.isEmpty
                )
                record.endpoints[index].ipv4Address = allocated.ip
                record.endpoints[index].ipv4Prefix = allocated.prefix
                record.endpoints[index].gateway = allocated.gateway
                record.endpoints[index].macAddress = allocated.mac
                record.endpoints[index].networkName = network.name
                interfaces.append(allocated.interface)
            case "bridge":
                try await allocateBridgeEndpoint(
                    record: &record,
                    index: index,
                    network: network,
                    interfaces: &interfaces,
                    openedBridge: &openedBridge
                )
            default:
                throw EngineError.notImplemented("network driver \"\(network.driver)\" is not implemented")
            }
        }
        return interfaces
    }

    func releaseInterfaces(_ containerID: String, keepAddresses: Bool = true) async {
        let nics = guestNics.removeValue(forKey: containerID) ?? []
        let networkIDs: Set<String>
        if !nics.isEmpty {
            networkIDs = Set(nics.map(\.networkID))
        } else if let record = containers[containerID] {
            networkIDs = record.networkIDs
        } else {
            networkIDs = Set(networkDataplane.ids)
        }
        for networkID in networkIDs {
            releaseVmnet(networkID: networkID, containerID: containerID)
        }
        if keepAddresses {
            await networkGateway.detach(containerID: containerID)
        } else {
            await networkGateway.forget(containerID: containerID)
        }
    }

    func recordGuestNics(_ record: EngineContainer) {
        var nics: [GuestNic] = []
        var sawBridge = false
        for endpoint in record.endpoints where !endpoint.ipv4Address.isEmpty {
            let driver = networks[endpoint.networkID]?.driver ?? ""
            if driver == "bridge" {
                if !sawBridge {
                    nics.append(
                        GuestNic(
                            interfaceName: "eth0",
                            networkID: endpoint.networkID,
                            ipv4Address: endpoint.ipv4Address,
                            ipv4Prefix: endpoint.ipv4Prefix,
                            gateway: endpoint.gateway,
                            macAddress: endpoint.macAddress,
                            inUse: true
                        )
                    )
                    sawBridge = true
                }
                continue
            }
            if driver == "host" {
                nics.append(
                    GuestNic(
                        interfaceName: "eth\(nics.count)",
                        networkID: endpoint.networkID,
                        ipv4Address: endpoint.ipv4Address,
                        ipv4Prefix: endpoint.ipv4Prefix,
                        gateway: endpoint.gateway,
                        macAddress: endpoint.macAddress,
                        inUse: true
                    )
                )
            }
        }
        guestNics[record.id] = nics
    }

    private func addGuestBridgeAddress(_ containerID: String, ip: String) async throws {
        let cidr = try CIDRv4("\(ip)/32")
        do {
            try await withGuestAgent(containerID) { agent in
                try await agent.addressAdd(name: "eth0", address: InterfaceAddress(ipv4Address: cidr))
            }
        } catch {
            if await guestHasAddress(containerID, ip: ip) {
                return
            }
            let added = try? await runGuest(
                containerID,
                command: ["ip", "addr", "add", "\(ip)/32", "dev", "eth0"],
                privileged: true
            )
            if added?.code != 0, !(await guestHasAddress(containerID, ip: ip)) {
                throw error
            }
        }
    }

    private func removeGuestBridgeAddress(_ containerID: String, ip: String) async throws {
        guard await guestHasAddress(containerID, ip: ip) else { return }
        var deleted = try? await runGuest(
            containerID,
            command: ["ip", "addr", "del", "\(ip)/32", "dev", "eth0"],
            privileged: true
        )
        if deleted?.code != 0 {
            deleted = try? await runGuest(
                containerID,
                command: ["ip", "addr", "del", ip, "dev", "eth0"],
                privileged: true
            )
        }
        if await guestHasAddress(containerID, ip: ip) {
            throw EngineError.runtimeUnavailable(
                "failed to remove \(ip) from eth0 (exit \(deleted?.code ?? -1))"
            )
        }
    }

    private func guestHasAddress(_ containerID: String, ip: String) async -> Bool {
        let show = try? await runGuest(containerID, command: ["ip", "-o", "addr", "show", "dev", "eth0"])
        guard let text = show?.stdout else { return false }
        return text.contains(" \(ip)/") || text.contains(" \(ip) ")
    }

    func applySecondaryBridgeAddresses(_ record: EngineContainer) async throws {
        let bridges = record.endpoints.filter { endpoint in
            networks[endpoint.networkID]?.driver == "bridge" && !endpoint.ipv4Address.isEmpty
        }
        for endpoint in bridges.dropFirst() {
            try await addGuestBridgeAddress(record.id, ip: endpoint.ipv4Address)
        }
    }

    func prepareGateway() async {
        guard !gatewayReady else { return }
        gatewayReady = true
        for network in networks.values {
            await networkGateway.registerNetwork(network)
        }
        for container in containers.values {
            for endpoint in container.endpoints {
                guard networks[endpoint.networkID]?.driver == "bridge",
                    !endpoint.ipv4Address.isEmpty,
                    let ip = try? IPv4Address(endpoint.ipv4Address)
                else { continue }
                try? await networkGateway.reserve(
                    endpoint.networkID,
                    key: NetworkGateway.endpointKey(containerID: container.id, networkID: endpoint.networkID),
                    ip: ip
                )
            }
        }
    }

    private func allocateBridgeEndpoint(
        record: inout EngineContainer,
        index: Int,
        network: EngineNetwork,
        interfaces: inout [any Interface],
        openedBridge: inout Bool
    ) async throws {
        await networkGateway.registerNetwork(network)
        let key = NetworkGateway.endpointKey(containerID: record.id, networkID: network.id)
        let ip: IPv4Address
        if !record.endpoints[index].ipv4Address.isEmpty,
            let existing = try? IPv4Address(record.endpoints[index].ipv4Address)
        {
            try await networkGateway.reserve(network.id, key: key, ip: existing)
            ip = existing
        } else {
            ip = try await networkGateway.allocate(network.id, key: key)
        }
        record.endpoints[index].ipv4Address = ip.description
        record.endpoints[index].ipv4Prefix = 32
        record.endpoints[index].gateway = NetworkGateway.gatewayAddress.description
        record.endpoints[index].networkName = network.name
        await networkGateway.bind(
            containerID: record.id,
            containerName: record.name,
            hostname: record.hostname,
            network: network,
            ip: ip,
            aliases: record.endpoints[index].aliases
        )
        if !openedBridge {
            let cidr = try CIDRv4("\(ip.description)/32")
            let iface = try await networkGateway.openLink(containerID: record.id, primary: cidr)
            record.endpoints[index].macAddress = iface.macAddress?.description ?? ""
            interfaces.append(iface)
            openedBridge = true
        } else if let mac = interfaces.first?.macAddress?.description {
            record.endpoints[index].macAddress = mac
        }
    }

    private func attachRunningEndpoint(
        _ container: EngineContainer,
        network: EngineNetwork,
        aliases: [String]
    ) async throws -> EngineEndpoint {
        _ = try NetworkAttachmentFactory.make(driver: network.driver)
        if network.driver == "host" {
            guard let nic = guestNic(container.id, networkID: network.id, inUse: false) else {
                throw EngineError.notImplemented(
                    "cannot hot-plug a new network interface on a running MicroVM; stop the container, connect, then start"
                )
            }
            try await withGuestAgent(container.id) { agent in
                try await agent.up(name: nic.interfaceName, mtu: nil)
            }
            setGuestNicInUse(container.id, networkID: network.id, inUse: true)
            return nic.asEndpoint(network: network, aliases: aliases)
        }
        guard network.driver == "bridge" else {
            throw EngineError.notImplemented("connecting a running container to \(network.name) is not implemented")
        }
        let hasBridgeNIC = container.endpoints.contains { endpoint in
            networks[endpoint.networkID]?.driver == "bridge" && !endpoint.ipv4Address.isEmpty
        }
        guard hasBridgeNIC else {
            throw EngineError.notImplemented(
                "cannot hot-plug a new network interface on a running MicroVM; stop the container, connect, then start"
            )
        }
        await prepareGateway()
        await networkGateway.registerNetwork(network)
        let key = NetworkGateway.endpointKey(containerID: container.id, networkID: network.id)
        let ip = try await networkGateway.allocate(network.id, key: key)
        try await addGuestBridgeAddress(container.id, ip: ip.description)
        await networkGateway.bind(
            containerID: container.id,
            containerName: container.name,
            hostname: container.hostname,
            network: network,
            ip: ip,
            aliases: aliases
        )
        let mac = container.endpoints.first(where: { !$0.macAddress.isEmpty })?.macAddress ?? ""
        return EngineEndpoint(
            networkID: network.id,
            networkName: network.name,
            ipv4Address: ip.description,
            ipv4Prefix: 32,
            gateway: NetworkGateway.gatewayAddress.description,
            macAddress: mac,
            aliases: aliases
        )
    }

    private func detachRunningEndpoint(_ container: EngineContainer, network: EngineNetwork) async throws {
        if network.driver == "host" {
            guard let nic = guestNic(container.id, networkID: network.id, inUse: true) else {
                return
            }
            try await withGuestAgent(container.id) { agent in
                try await agent.down(name: nic.interfaceName)
            }
            setGuestNicInUse(container.id, networkID: network.id, inUse: false)
            return
        }
        guard network.driver == "bridge" else { return }
        guard let endpoint = container.endpoints.first(where: { $0.networkID == network.id }),
            !endpoint.ipv4Address.isEmpty
        else { return }
        let remaining = container.endpoints.filter { item in
            item.networkID != network.id && networks[item.networkID]?.driver == "bridge"
        }
        if remaining.isEmpty {
            try await withGuestAgent(container.id) { agent in
                try await agent.down(name: "eth0")
            }
        } else {
            try await removeGuestBridgeAddress(container.id, ip: endpoint.ipv4Address)
        }
        await networkGateway.unbind(containerID: container.id, networkID: network.id)
    }

    private func guestNic(_ containerID: String, networkID: String, inUse: Bool) -> GuestNic? {
        guestNics[containerID]?.first { $0.networkID == networkID && $0.inUse == inUse }
    }

    private func setGuestNicInUse(_ containerID: String, networkID: String, inUse: Bool) {
        guard var nics = guestNics[containerID],
            let index = nics.firstIndex(where: { $0.networkID == networkID })
        else { return }
        nics[index].inUse = inUse
        guestNics[containerID] = nics
    }

    func dnsConfig(for record: EngineContainer) -> DNS? {
        let attached = record.endpoints.compactMap { endpoint in networks[endpoint.networkID] }
        guard attached.contains(where: { $0.driver != "none" }) else {
            return nil
        }
        if attached.contains(where: { $0.driver == "bridge" }) {
            return DNS(nameservers: [NetworkGateway.gatewayAddress.description])
        }
        return DNS(nameservers: DNS.defaultNameservers + ["8.8.8.8"])
    }

    func startPortPublishers(_ record: EngineContainer) async throws {
        let mode = normalizedNetworkMode(record.networkMode)
        guard mode != "none" else { return }
        let ip = record.endpoints.first(where: { !$0.ipv4Address.isEmpty })?.ipv4Address ?? ""
        guard !ip.isEmpty else { return }

        let bindings = mode == "host" ? record.exposedPorts : record.portBindings

        let bridgeTarget = record.endpoints.first { endpoint in
            networks[endpoint.networkID]?.driver == "bridge" && !endpoint.ipv4Address.isEmpty
        }
        var updated = record
        var published: [EnginePortBinding] = []
        for (index, binding) in bindings.enumerated() {
            let key = "\(record.id):\(index)"
            let destIP: String
            let destPort: Int
            if let bridgeTarget, let guestIP = try? IPv4Address(bridgeTarget.ipv4Address) {
                destIP = "127.0.0.1"
                destPort = try await networkGateway.startPortRelay(
                    guestIP: guestIP,
                    guestPort: UInt16(binding.containerPort),
                    udp: binding.protocolName.lowercased() == "udp"
                )
            } else {
                destIP = ip
                destPort = binding.containerPort
            }
            let bound = try await portPublisher.publish(
                key: key,
                hostIP: binding.hostIP,
                hostPort: binding.hostPort,
                containerIP: destIP,
                containerPort: destPort,
                protocolName: binding.protocolName
            )
            published.append(
                EnginePortBinding(
                    hostIP: binding.hostIP,
                    hostPort: bound,
                    containerPort: binding.containerPort,
                    protocolName: binding.protocolName
                )
            )
        }
        updated.portBindings = published
        saveContainer(updated)
    }

    func stopPortPublishers(_ containerID: String) async {
        portPublisher.unpublish(keysMatching: "\(containerID):")
        guard let record = containers[containerID] else { return }
        let guest = record.endpoints.first { endpoint in
            networks[endpoint.networkID]?.driver == "bridge" && !endpoint.ipv4Address.isEmpty
        }
        guard let guest, let guestIP = try? IPv4Address(guest.ipv4Address) else { return }
        for binding in record.portBindings {
            await networkGateway.stopPortRelay(
                guestIP: guestIP,
                guestPort: UInt16(binding.containerPort),
                udp: binding.protocolName.lowercased() == "udp"
            )
        }
    }

    func resolveNetwork(_ idOrName: String) throws -> EngineNetwork {
        let key = idOrName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let network = networks[key] {
            return network
        }
        if let network = networks.values.first(where: { $0.name == key || $0.id.hasPrefix(key) }) {
            return network
        }
        throw EngineError.networkNotFound("network \(idOrName) not found")
    }

    static func loadNetworks(from root: URL) -> [String: EngineNetwork] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var loaded: [String: EngineNetwork] = [:]
        for dir in dirs {
            let config = dir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: config),
                let network = try? decoder.decode(EngineNetwork.self, from: data)
            else {
                continue
            }
            loaded[network.id] = network
        }
        return loaded
    }

    static func ensureBuiltinNetworks(into networks: inout [String: EngineNetwork], root: URL) throws {
        try ensureBuiltin(
            name: builtinBridgeName,
            driver: "bridge",
            subnet: defaultBridgeSubnet,
            into: &networks,
            root: root
        )
        try ensureBuiltin(
            name: builtinHostName,
            driver: "host",
            subnet: defaultHostSubnet,
            into: &networks,
            root: root
        )
        try ensureBuiltin(
            name: builtinNoneName,
            driver: "none",
            subnet: "",
            into: &networks,
            root: root
        )
    }

    static func isValidNetworkName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private func inspectPayload(_ network: EngineNetwork) -> EngineNetworkInspect {
        let attached: [EngineNetworkContainer] = containers.values.compactMap { container in
            guard let endpoint = container.endpoints.first(where: { $0.networkID == network.id }) else {
                return nil
            }
            let prefix = endpoint.ipv4Prefix > 0 ? endpoint.ipv4Prefix : prefixLength(network.subnet)
            let cidr = endpoint.ipv4Address.isEmpty ? "" : "\(endpoint.ipv4Address)/\(prefix)"
            return EngineNetworkContainer(
                id: container.id,
                name: container.name,
                endpointID: String(container.id.prefix(12)) + String(network.id.prefix(12)),
                macAddress: endpoint.macAddress,
                ipv4Address: cidr
            )
        }
        return EngineNetworkInspect(network: network, containers: attached.sorted { $0.name < $1.name })
    }

    private func endpoint(for network: EngineNetwork, aliases: [String]) -> EngineEndpoint {
        EngineEndpoint(
            networkID: network.id,
            networkName: network.name,
            ipv4Address: "",
            ipv4Prefix: prefixLength(network.subnet),
            gateway: network.gateway,
            macAddress: "",
            aliases: aliases
        )
    }

    private func validateAttachment(mode: String, extra: EngineNetwork) throws {
        if mode == "host", extra.name != Self.builtinHostName, extra.driver != "host" {
            throw EngineError.invalidArgument("cannot connect host-mode containers to \(extra.name)")
        }
        if mode == "none", extra.name != Self.builtinNoneName, extra.driver != "none" {
            throw EngineError.invalidArgument("cannot connect none-mode containers to \(extra.name)")
        }
    }

    private func normalizedNetworkMode(_ raw: String) -> String {
        let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode.isEmpty || mode == "default" || mode == "bridge" {
            return Self.builtinBridgeName
        }
        return mode
    }

    private func resolveNetworkName(_ idOrName: String) -> String? {
        (try? resolveNetwork(idOrName))?.name
    }

    private func networkRefCount(_ id: String) -> Int {
        containers.values.filter { container in
            container.endpoints.contains { $0.networkID == id }
        }.count
    }

    private func nextSubnet() throws -> String {
        for octet in 17...31 {
            let candidate = "172.\(octet).0.0/16"
            if networks.values.contains(where: { $0.subnet == candidate }) {
                continue
            }
            return candidate
        }
        throw EngineError.invalidArgument("no free 172.x.0.0/16 subnet")
    }

    private func persistNetwork(_ network: EngineNetwork) throws {
        try Self.writeNetwork(network, to: networkRoot)
    }

    private static func writeNetwork(_ network: EngineNetwork, to root: URL) throws {
        let dir = root.appendingPathComponent(network.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(network).write(to: dir.appendingPathComponent("config.json"), options: .atomic)
    }

    private func removeNetworkFiles(_ id: String) throws {
        let dir = networkRoot.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func prefixLength(_ subnet: String) -> Int {
        let parts = subnet.split(separator: "/")
        return parts.count == 2 ? Int(parts[1]) ?? 16 : 16
    }

    private static func gateway(for subnet: String) -> String {
        let ip = subnet.split(separator: "/").first.map(String.init) ?? subnet
        let parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return "172.17.0.1" }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }

    private static func normalizedSubnet(_ raw: String) throws -> String {
        do {
            return try CIDRv4(raw).description
        } catch {
            throw EngineError.invalidArgument("invalid subnet \(raw)")
        }
    }

    private static func ensureBuiltin(
        name: String,
        driver: String,
        subnet: String,
        into networks: inout [String: EngineNetwork],
        root: URL
    ) throws {
        if networks.values.contains(where: { $0.name == name }) {
            return
        }
        let network = EngineNetwork(
            id: makeContainerID(),
            name: name,
            driver: driver,
            scope: "local",
            created: Date(),
            labels: [:],
            subnet: subnet,
            gateway: subnet.isEmpty ? "" : gateway(for: subnet),
            internalNetwork: false,
            builtin: true
        )
        try writeNetwork(network, to: root)
        networks[network.id] = network
    }

    private struct AllocatedInterface {
        var interface: any Interface
        var ip: String
        var prefix: Int
        var gateway: String
        var mac: String
    }

    private func allocateInterface(network: EngineNetwork, containerID: String, secondary: Bool) throws -> AllocatedInterface {
        guard #available(macOS 26.0, *) else {
            throw EngineError.runtimeUnavailable("container networking requires macOS 26 or later")
        }
        var vmnet = try vmnetNetwork(for: network)
        releaseVmnetLocked(vmnet: &vmnet, containerID: containerID)
        let created: (any Interface)?
        if network.internalNetwork || secondary {
            created = try vmnet.createInterfaceWithoutGateway(containerID)
        } else {
            created = try vmnet.createInterface(containerID)
        }
        networkDataplane.set(network.id, vmnet)
        guard let created else {
            throw EngineError.runtimeUnavailable("failed to allocate an interface on network \(network.name)")
        }

        let actualSubnet = vmnet.subnet.description
        let actualGateway = vmnet.ipv4Gateway.description
        if var stored = networks[network.id], stored.subnet != actualSubnet || stored.gateway != actualGateway {
            stored.subnet = actualSubnet
            stored.gateway = actualGateway
            networks[network.id] = stored
            try? persistNetwork(stored)
        }

        return AllocatedInterface(
            interface: created,
            ip: created.ipv4Address.address.description,
            prefix: Int(created.ipv4Address.prefix.length),
            gateway: created.ipv4Gateway?.description ?? actualGateway,
            mac: created.macAddress?.description ?? ""
        )
    }

    @available(macOS 26.0, *)
    private func vmnetNetwork(for network: EngineNetwork) throws -> VmnetNetwork {
        if let existing = networkDataplane.get(network.id) {
            return existing
        }
        if !network.subnet.isEmpty, let cidr = try? CIDRv4(network.subnet) {
            do {
                let created = try VmnetNetwork(subnet: cidr)
                networkDataplane.set(network.id, created)
                return created
            } catch {
                let created = try VmnetNetwork()
                networkDataplane.set(network.id, created)
                return created
            }
        }
        let created = try VmnetNetwork()
        networkDataplane.set(network.id, created)
        return created
    }

    private func releaseVmnet(networkID: String, containerID: String) {
        guard #available(macOS 26.0, *) else { return }
        guard var vmnet = networkDataplane.get(networkID) else { return }
        releaseVmnetLocked(vmnet: &vmnet, containerID: containerID)
        networkDataplane.set(networkID, vmnet)
    }

    @available(macOS 26.0, *)
    private func releaseVmnetLocked(vmnet: inout VmnetNetwork, containerID: String) {
        try? vmnet.releaseInterface(containerID)
    }
}
