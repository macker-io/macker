import Containerization
import Foundation

/// Type-erased store for `VmnetNetwork` values (macOS 26+).
final class NetworkDataplane: @unchecked Sendable {
    private var storage: [String: Any] = [:]

    var ids: [String] { Array(storage.keys) }

    func remove(_ id: String) {
        storage[id] = nil
    }

    @available(macOS 26.0, *)
    func get(_ id: String) -> VmnetNetwork? {
        storage[id] as? VmnetNetwork
    }

    @available(macOS 26.0, *)
    func set(_ id: String, _ network: VmnetNetwork) {
        storage[id] = network
    }
}
