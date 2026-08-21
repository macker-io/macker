import Containerization
import ContainerizationExtras
import Foundation

/// How an endpoint is realized on a MicroVM: `bridge` goes through ``NetworkGateway``,
/// `host` gets its own vmnet NIC, `none` gets nothing.
protocol NetworkAttachment: Sendable {
    var driver: String { get }
}

struct BridgeAttachment: NetworkAttachment {
    let driver = "bridge"
}

struct HostAttachment: NetworkAttachment {
    let driver = "host"
}

struct NoneAttachment: NetworkAttachment {
    let driver = "none"
}

/// Single gate for "is this driver supported", so unimplemented drivers fail the same way
/// on create, on start, and on `network connect`.
enum NetworkAttachmentFactory {
    static func make(driver: String) throws -> any NetworkAttachment {
        switch driver {
        case "bridge":
            return BridgeAttachment()
        case "host":
            return HostAttachment()
        case "none":
            return NoneAttachment()
        case "macvlan", "ipvlan":
            throw EngineError.notImplemented("network driver \"\(driver)\" is not implemented")
        default:
            if driver.hasPrefix("container:") {
                throw EngineError.notImplemented("network mode \(driver) is not implemented")
            }
            throw EngineError.invalidArgument("network driver \"\(driver)\" is not supported")
        }
    }
}
