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

    /// `always` / `unless-stopped` come back after the daemon process exits.
    public var resumesAfterDaemonExit: Bool {
        name == "always" || name == "unless-stopped"
    }

    public func shouldRestart(exitCode: Int, action: String, restartCount: Int) -> Bool {
        if action == "shutdown" || Self.isUserStop(action) {
            return false
        }
        switch name {
        case "always", "unless-stopped":
            return true
        case "on-failure":
            guard exitCode != 0 else { return false }
            if maximumRetryCount <= 0 { return true }
            return restartCount < maximumRetryCount
        default:
            return false
        }
    }

    /// Docker daemon restart: `always` starts any container that has run; `unless-stopped`
    /// starts only those that were still running (or paused) when the daemon died.
    public func shouldStartAfterDaemonRestart(wasActive: Bool, hasStarted: Bool) -> Bool {
        switch name {
        case "always":
            return hasStarted
        case "unless-stopped":
            return wasActive
        default:
            return false
        }
    }

    private static func isUserStop(_ action: String) -> Bool {
        action == "stop" || action == "kill"
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

    public static let defaultIntervalNanos: Int64 = 30_000_000_000
    public static let defaultTimeoutNanos: Int64 = 30_000_000_000
    public static let defaultStartIntervalNanos: Int64 = 5_000_000_000
    public static let defaultRetries = 3
    public static let maxLogEntries = 5
    public static let maxOutputBytes = 4096

    public var isDisabled: Bool {
        test.isEmpty || test.first?.uppercased() == "NONE"
    }

    public var command: [String]? {
        guard !isDisabled else { return nil }
        if test.first == "CMD-SHELL" {
            return ["/bin/sh", "-c", test.dropFirst().joined(separator: " ")]
        }
        if test.first == "CMD" {
            let args = Array(test.dropFirst())
            return args.isEmpty ? nil : args
        }
        return test
    }

    public var interval: TimeInterval {
        Double(intervalNanos > 0 ? intervalNanos : Self.defaultIntervalNanos) / 1_000_000_000
    }

    public var timeout: TimeInterval {
        Double(timeoutNanos > 0 ? timeoutNanos : Self.defaultTimeoutNanos) / 1_000_000_000
    }

    public var startPeriod: TimeInterval {
        Double(max(startPeriodNanos, 0)) / 1_000_000_000
    }

    public var startInterval: TimeInterval {
        Double(startIntervalNanos > 0 ? startIntervalNanos : Self.defaultStartIntervalNanos) / 1_000_000_000
    }

    public var retryLimit: Int {
        retries > 0 ? retries : Self.defaultRetries
    }

    var commitConfig: CommitHealthcheck {
        CommitHealthcheck(
            Test: test,
            Interval: intervalNanos == 0 ? nil : intervalNanos,
            Timeout: timeoutNanos == 0 ? nil : timeoutNanos,
            StartPeriod: startPeriodNanos == 0 ? nil : startPeriodNanos,
            StartInterval: startIntervalNanos == 0 ? nil : startIntervalNanos,
            Retries: retries == 0 ? nil : retries
        )
    }

    /// `HEALTHCHECK [OPTIONS] CMD ...` / `HEALTHCHECK NONE`.
    public static func parseDockerfile(arguments: String, flags: DockerfileFlags = DockerfileFlags()) throws -> EngineHealthcheck {
        let rest = arguments.trimmingCharacters(in: .whitespaces)
        if rest.uppercased() == "NONE" {
            return EngineHealthcheck(test: ["NONE"])
        }
        guard rest.uppercased().hasPrefix("CMD") else {
            throw EngineError.invalidArgument("HEALTHCHECK requires CMD or NONE")
        }
        let body = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        let test: [String]
        if body.hasPrefix("[") {
            test = ["CMD"] + (try parseJSONArray(body))
        } else {
            guard !body.isEmpty else {
                throw EngineError.invalidArgument("HEALTHCHECK CMD requires a command")
            }
            test = ["CMD-SHELL", body]
        }
        return EngineHealthcheck(
            test: test,
            intervalNanos: try nanos(flags["interval"]),
            timeoutNanos: try nanos(flags["timeout"]),
            startPeriodNanos: try nanos(flags["start-period"]),
            startIntervalNanos: try nanos(flags["start-interval"]),
            retries: flags["retries"].flatMap(Int.init) ?? 0
        )
    }

    public static func inherit(_ specified: EngineHealthcheck?, image: EngineHealthcheck?) -> EngineHealthcheck? {
        if let specified {
            return specified.isDisabled ? nil : specified
        }
        guard let image, !image.isDisabled else { return nil }
        return image
    }

    private static func nanos(_ raw: String?) throws -> Int64 {
        guard let raw, !raw.isEmpty else { return 0 }
        guard let duration = ISO8601.parseGoDuration(raw) else {
            throw EngineError.invalidArgument("invalid duration: \(raw)")
        }
        return Int64(duration * 1_000_000_000)
    }

    private static func parseJSONArray(_ raw: String) throws -> [String] {
        guard let data = raw.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else {
            throw EngineError.invalidArgument("HEALTHCHECK CMD JSON array is invalid")
        }
        return values
    }
}

public struct EngineHealthLog: Sendable, Codable, Equatable {
    public var start: Date
    public var end: Date
    public var exitCode: Int
    public var output: String

    public init(start: Date, end: Date, exitCode: Int, output: String) {
        self.start = start
        self.end = end
        self.exitCode = exitCode
        self.output = output
    }
}

public struct EngineHealthState: Sendable, Codable, Equatable {
    public var status: String
    public var failingStreak: Int
    public var log: [EngineHealthLog]

    public init(status: String = "starting", failingStreak: Int = 0, log: [EngineHealthLog] = []) {
        self.status = status
        self.failingStreak = failingStreak
        self.log = log
    }

    /// Applies one probe. Failures during `startPeriod` do not count toward `unhealthy`.
    public mutating func apply(exitCode: Int, startedAt: Date, spec: EngineHealthcheck, now: Date = Date()) {
        let succeeded = exitCode == 0
        let inStart = now.timeIntervalSince(startedAt) < spec.startPeriod
        if succeeded {
            failingStreak = 0
            status = "healthy"
            return
        }
        if inStart {
            status = "starting"
            return
        }
        failingStreak += 1
        status = failingStreak >= spec.retryLimit ? "unhealthy" : "starting"
    }

    public mutating func append(_ entry: EngineHealthLog) {
        log.append(entry)
        if log.count > EngineHealthcheck.maxLogEntries {
            log.removeFirst(log.count - EngineHealthcheck.maxLogEntries)
        }
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
    /// Docker `--add-host host:ip`. `host-gateway` stays a token until `hostGateway` is supplied
    /// (the container's per-network gateway, typically `172.17.0.1`).
    public static func parse(_ raw: String, hostGateway: String? = nil) throws -> (host: String, ip: String) {
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
            ip = hostGateway ?? ip
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
