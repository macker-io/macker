import Foundation

public struct EngineRestartPolicy: Sendable, Codable, Equatable {
    public var name: String
    public var maximumRetryCount: Int

    public static let none = EngineRestartPolicy(name: "no", maximumRetryCount: 0)

    public init(name: String = "no", maximumRetryCount: Int = 0) {
        self.name = name
        self.maximumRetryCount = maximumRetryCount
    }

    /// Docker `--restart no|always|unless-stopped|on-failure[:N]`.
    public static func parse(_ raw: String) throws -> EngineRestartPolicy {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "no" || trimmed == "none" {
            return .none
        }
        if trimmed == "always" || trimmed == "unless-stopped" {
            return EngineRestartPolicy(name: trimmed, maximumRetryCount: 0)
        }
        if trimmed == "on-failure" {
            return EngineRestartPolicy(name: "on-failure", maximumRetryCount: 0)
        }
        if trimmed.hasPrefix("on-failure:") {
            let count = String(trimmed.dropFirst("on-failure:".count))
            guard let value = Int(count), value >= 0 else {
                throw EngineError.invalidArgument("invalid restart policy: \(raw)")
            }
            return EngineRestartPolicy(name: "on-failure", maximumRetryCount: value)
        }
        throw EngineError.invalidArgument("invalid restart policy: \(raw)")
    }

    public func shouldRestart(exitCode: Int, action: String, restartCount: Int) -> Bool {
        if action == "shutdown" {
            return false
        }
        switch name {
        case "always":
            return true
        case "unless-stopped":
            return action != "stop" && action != "kill"
        case "on-failure":
            if action == "stop" || action == "kill" { return false }
            guard exitCode != 0 else { return false }
            if maximumRetryCount <= 0 { return true }
            return restartCount < maximumRetryCount
        default:
            return false
        }
    }
}

public struct EngineHealthcheck: Sendable, Codable, Equatable {
    public var test: [String]
    public var intervalNanos: Int64
    public var timeoutNanos: Int64
    public var startPeriodNanos: Int64
    public var startIntervalNanos: Int64
    public var retries: Int

    public init(
        test: [String] = [],
        intervalNanos: Int64 = 0,
        timeoutNanos: Int64 = 0,
        startPeriodNanos: Int64 = 0,
        startIntervalNanos: Int64 = 0,
        retries: Int = 0
    ) {
        self.test = test
        self.intervalNanos = intervalNanos
        self.timeoutNanos = timeoutNanos
        self.startPeriodNanos = startPeriodNanos
        self.startIntervalNanos = startIntervalNanos
        self.retries = retries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decodeIfPresent([String].self, forKey: .test) ?? []
        intervalNanos = try container.decodeIfPresent(Int64.self, forKey: .intervalNanos) ?? 0
        timeoutNanos = try container.decodeIfPresent(Int64.self, forKey: .timeoutNanos) ?? 0
        startPeriodNanos = try container.decodeIfPresent(Int64.self, forKey: .startPeriodNanos) ?? 0
        startIntervalNanos = try container.decodeIfPresent(Int64.self, forKey: .startIntervalNanos) ?? 0
        retries = try container.decodeIfPresent(Int.self, forKey: .retries) ?? 0
    }
}

public struct EngineContainerRunConfig: Sendable, Codable, Equatable {
    public var extraHosts: [String]
    public var dns: [String]
    public var dnsSearch: [String]
    public var dnsOptions: [String]
    public var restartPolicy: EngineRestartPolicy
    public var restartCount: Int
    public var stopSignal: String
    public var stopTimeout: Int
    public var privileged: Bool
    public var readonlyRootfs: Bool
    public var domainname: String
    public var groupAdd: [String]
    public var publishAllPorts: Bool
    public var healthcheck: EngineHealthcheck?

    public init(
        extraHosts: [String] = [],
        dns: [String] = [],
        dnsSearch: [String] = [],
        dnsOptions: [String] = [],
        restartPolicy: EngineRestartPolicy = .none,
        restartCount: Int = 0,
        stopSignal: String = "",
        stopTimeout: Int = 0,
        privileged: Bool = false,
        readonlyRootfs: Bool = false,
        domainname: String = "",
        groupAdd: [String] = [],
        publishAllPorts: Bool = false,
        healthcheck: EngineHealthcheck? = nil
    ) {
        self.extraHosts = extraHosts
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.dnsOptions = dnsOptions
        self.restartPolicy = restartPolicy
        self.restartCount = restartCount
        self.stopSignal = stopSignal
        self.stopTimeout = stopTimeout
        self.privileged = privileged
        self.readonlyRootfs = readonlyRootfs
        self.domainname = domainname
        self.groupAdd = groupAdd
        self.publishAllPorts = publishAllPorts
        self.healthcheck = healthcheck
    }
}

public struct EngineNetworkAttachSpec: Sendable, Equatable {
    public var name: String
    public var ipv4: String?
    public var ipv6: String?
    public var aliases: [String]
    public var macAddress: String?
    public var linkLocalIPs: [String]

    public init(
        name: String,
        ipv4: String? = nil,
        ipv6: String? = nil,
        aliases: [String] = [],
        macAddress: String? = nil,
        linkLocalIPs: [String] = []
    ) {
        self.name = name
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.aliases = aliases
        self.macAddress = macAddress
        self.linkLocalIPs = linkLocalIPs
    }

    /// Docker `--network name` or `--network name=foo,ip=1.2.3.4,alias=web`.
    public static func parse(_ raw: String) throws -> EngineNetworkAttachSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineError.invalidArgument("invalid network: \(raw)")
        }
        if !trimmed.contains(",") && !trimmed.contains("=") {
            return EngineNetworkAttachSpec(name: trimmed)
        }
        var name = ""
        var ipv4: String?
        var ipv6: String?
        var aliases: [String] = []
        var mac: String?
        var linkLocal: [String] = []
        for part in trimmed.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            let split = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard split.count == 2 else {
                throw EngineError.invalidArgument("invalid network: \(raw)")
            }
            switch split[0] {
            case "name", "network":
                name = split[1]
            case "ip":
                ipv4 = split[1]
            case "ip6":
                ipv6 = split[1]
            case "alias":
                if !split[1].isEmpty { aliases.append(split[1]) }
            case "mac", "mac-address":
                mac = split[1]
            case "link-local-ip":
                if !split[1].isEmpty { linkLocal.append(split[1]) }
            default:
                throw EngineError.invalidArgument("invalid network option \(split[0])")
            }
        }
        if name.isEmpty {
            throw EngineError.invalidArgument("invalid network: \(raw)")
        }
        return EngineNetworkAttachSpec(
            name: name,
            ipv4: ipv4,
            ipv6: ipv6,
            aliases: aliases,
            macAddress: mac,
            linkLocalIPs: linkLocal
        )
    }

    public func asRequest() throws -> EngineEndpointRequest {
        if let ipv6, !ipv6.isEmpty {
            throw EngineError.notImplemented("IPv6 is not implemented")
        }
        return EngineEndpointRequest(
            network: name,
            aliases: aliases,
            ipv4: ipv4,
            macAddress: macAddress,
            linkLocalIPs: linkLocalIPs
        )
    }
}

public enum EngineVolumeSpec {
    /// Docker `--mount type=bind,source=/host,target=/c,readonly`.
    public static func parseMount(_ raw: String) throws -> EngineVolumeRequest {
        var type = "volume"
        var source = ""
        var destination = ""
        var readOnly = false
        for part in raw.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            let split = piece.split(separator: "=", maxSplits: 1).map(String.init)
            if split.count == 1, split[0] == "readonly" || split[0] == "ro" {
                readOnly = true
                continue
            }
            guard split.count == 2 else {
                throw EngineError.invalidArgument("invalid mount: \(raw)")
            }
            switch split[0] {
            case "type":
                type = split[1].lowercased()
            case "source", "src":
                source = split[1]
            case "target", "dst", "destination":
                destination = split[1]
            case "readonly", "ro":
                readOnly = FilterMatch.isTrue([split[1]])
            case "volume-driver", "bind-propagation", "consistency", "tmpfs-size", "tmpfs-mode",
                "volume-opt", "bind-nonrecursive", "bind-recursive", "volume-nocopy":
                continue
            default:
                throw EngineError.invalidArgument("invalid mount option \(split[0])")
            }
        }
        guard !destination.isEmpty else {
            throw EngineError.invalidArgument("invalid mount: \(raw)")
        }
        if type == "tmpfs" {
            return EngineVolumeRequest(type: "tmpfs", source: "", destination: destination, readOnly: false)
        }
        if type != "bind" && type != "volume" {
            throw EngineError.invalidArgument("mount type \"\(type)\" is not supported")
        }
        return EngineVolumeRequest(
            type: type,
            source: source,
            destination: destination,
            readOnly: readOnly,
            anonymous: type == "volume" && source.isEmpty
        )
    }

    /// Docker `--tmpfs /run[:options]`.
    public static func parseTmpfs(_ raw: String) throws -> EngineVolumeRequest {
        let destination = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? raw
        guard destination.hasPrefix("/") else {
            throw EngineError.invalidArgument("invalid tmpfs: \(raw)")
        }
        return EngineVolumeRequest(type: "tmpfs", source: "", destination: destination, readOnly: false)
    }

    /// Docker `--volumes-from container[:ro|rw]`.
    public static func parseVolumesFrom(_ raw: String) -> (name: String, readOnly: Bool?) {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return (raw, nil)
        }
        switch parts[1] {
        case "ro": return (parts[0], true)
        case "rw": return (parts[0], false)
        default: return (raw, nil)
        }
    }
}

public enum EngineExtraHost {
    /// Docker `--add-host host:ip`. `host-gateway` maps to the userspace gateway.
    public static func parse(_ raw: String) throws -> (host: String, ip: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":") else {
            throw EngineError.invalidArgument("invalid extra host: \(raw)")
        }
        let host = String(trimmed[..<colon])
        var ip = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, !ip.isEmpty else {
            throw EngineError.invalidArgument("invalid extra host: \(raw)")
        }
        if ip == "host-gateway" {
            ip = NetworkGateway.gatewayAddress.description
        }
        return (host, ip)
    }
}

public enum EngineLabelFile {
    public static func parse(_ text: String) -> [String: String] {
        var labels: [String: String] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            labels[key] = parts.count == 2 ? parts[1] : ""
        }
        return labels
    }
}
