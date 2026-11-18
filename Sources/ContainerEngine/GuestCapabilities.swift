import Foundation
import Containerization
import ContainerizationOS

/// Capability sets for the workload inside a container's MicroVM.
///
/// Every container has its own kernel, so `--privileged` and `--cap-add` widen what the
/// workload may do *inside its VM* (mount, network admin, device nodes of the VM, …); they do
/// not reach the Mac host. Semantics follow Docker's `TweakCapabilities`.
public enum GuestCapabilities {
    /// Docker's default set, which is also the `containerization` default.
    static var defaults: [CapabilityName] { LinuxCapabilities.defaultOCICapabilities.bounding }

    /// Bounding/effective/permitted set (Docker leaves inheritable and ambient empty).
    public static func resolve(privileged: Bool, add: [String], drop: [String]) throws -> [CapabilityName] {
        if privileged {
            return CapabilityName.allCases
        }
        if add.isEmpty && drop.isEmpty {
            return defaults
        }
        let (adds, addAll) = try normalize(add, flag: "--cap-add")
        let (drops, dropAll) = try normalize(drop, flag: "--cap-drop")
        var caps: [CapabilityName]
        if addAll {
            caps = CapabilityName.allCases
        } else if dropAll {
            caps = adds
        } else {
            caps = defaults
            for cap in adds where !caps.contains(cap) {
                caps.append(cap)
            }
        }
        if !dropAll {
            // An explicit add wins over a drop of the same capability (Docker ≥ 20.10).
            caps.removeAll { drops.contains($0) && !adds.contains($0) }
        }
        return caps
    }

    static func processCapabilities(privileged: Bool, add: [String], drop: [String]) throws -> LinuxCapabilities {
        LinuxCapabilities(capabilities: try resolve(privileged: privileged, add: add, drop: drop))
    }

    private static func normalize(_ names: [String], flag: String) throws -> ([CapabilityName], Bool) {
        var result: [CapabilityName] = []
        var all = false
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if name.uppercased() == "ALL" || name.uppercased() == "CAP_ALL" {
                all = true
                continue
            }
            guard let cap = try? CapabilityName(rawValue: name) else {
                throw EngineError.invalidArgument("unknown capability: \"\(raw)\" (\(flag))")
            }
            if !result.contains(cap) {
                result.append(cap)
            }
        }
        return (result, all)
    }
}
