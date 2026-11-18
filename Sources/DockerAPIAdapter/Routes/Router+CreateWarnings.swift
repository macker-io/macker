import Foundation

extension Router {
    /// Non-default HostConfig values this runtime does not apply. Empty Docker defaults stay quiet.
    static func unsupportedCreateWarnings(_ body: Data) -> [String] {
        guard !body.isEmpty,
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return []
        }
        var warnings: [String] = []
        if let mac = root["MacAddress"] as? String, !mac.isEmpty {
            warnings.append("MacAddress is not applied; virtio-net assigns the guest MAC")
        }
        if let host = root["HostConfig"] as? [String: Any] {
            warnings.append(contentsOf: hostConfigWarnings(host))
        }
        return warnings
    }

    private static let appliedHostKeys: Set<String> = [
        "Memory", "NanoCpus", "AutoRemove", "NetworkMode", "Binds", "Mounts", "PortBindings",
        "PublishAllPorts", "Dns", "DnsSearch", "DnsOptions", "ExtraHosts", "RestartPolicy",
        "StopSignal", "StopTimeout", "VolumesFrom", "VolumeDriver",
        "Init", "Sysctls", "CapAdd", "CapDrop", "Ulimits",
    ]

    private static func hostConfigWarnings(_ host: [String: Any]) -> [String] {
        var warnings: [String] = []
        func warn(_ message: String) { warnings.append(message) }
        func ignored(_ key: String) {
            warn("\(key) is not supported on this runtime and was ignored")
        }

        // -1 is Docker's default sentinel, not a request to configure swappiness.
        if let swappiness = host["MemorySwappiness"] as? NSNumber, swappiness.intValue != -1 {
            ignored("MemorySwappiness")
        }
        if isSet(host["GroupAdd"]) {
            warn("GroupAdd is recorded on inspect but is not applied in the guest")
        }
        if isSet(host["Tmpfs"]) {
            warn("Tmpfs is a host directory plus virtiofs, not a kernel tmpfs")
        }
        if let opts = host["SecurityOpt"] as? [String],
            opts.contains(where: { !$0.hasPrefix("no-new-privileges") })
        {
            ignored("SecurityOpt")
        }
        if let log = host["LogConfig"] as? [String: Any] {
            let type = (log["Type"] as? String)?.lowercased() ?? ""
            if !type.isEmpty, type != "json-file", type != "local" {
                ignored("LogConfig")
            }
        }
        for key in ["PidMode", "IpcMode", "UTSMode", "CgroupnsMode", "UsernsMode", "Isolation", "Runtime"] {
            guard let raw = host[key] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty || value == "private" || value == "default" || value == "runc" || value == "containerization" {
                continue
            }
            ignored(key)
        }
        if let size = host["ConsoleSize"] as? [Any], size.contains(where: { number($0) != 0 }) {
            ignored("ConsoleSize")
        }
        if number(host["ShmSize"]) != 0 {
            ignored("ShmSize")
        }

        let specific: Set<String> = [
            "Privileged", "ReadonlyRootfs", "GroupAdd", "Tmpfs", "SecurityOpt", "LogConfig",
            "PidMode", "IpcMode", "UTSMode", "CgroupnsMode", "UsernsMode", "Isolation", "Runtime",
            "ConsoleSize", "ShmSize", "MemorySwappiness",
        ]
        for key in host.keys.sorted() {
            if appliedHostKeys.contains(key) || specific.contains(key) { continue }
            guard isSet(host[key]) else { continue }
            ignored(key)
        }
        return warnings
    }

    private static func isSet(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return false }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number.doubleValue != 0
        }
        if let text = value as? String { return !text.isEmpty }
        if let list = value as? [Any] { return !list.isEmpty }
        if let object = value as? [String: Any] { return !object.isEmpty }
        return true
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}
