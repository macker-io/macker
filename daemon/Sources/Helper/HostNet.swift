import Darwin
import Foundation
import MackerHelperSupport

final class HostNet: @unchecked Sendable {
    private var routes: [String: Set<String>] = [:]

    func apply(_ command: ValidatedHelperRequest) throws -> (fd: Int32, name: String)? {
        switch command {
        case .ping:
            return nil
        case .attach(let address, let peer, let prefix, let extraRoutes):
            let opened = try UtunControl.open()
            do {
                try HostNetCommands.configure(
                    interface: opened.name,
                    address: address,
                    peer: peer,
                    prefix: prefix
                )
                var applied: Set<String> = []
                for subnet in extraRoutes {
                    try HostNetCommands.addRoute(interface: opened.name, subnet: subnet)
                    applied.insert(subnet)
                }
                routes[opened.name] = applied
                return opened
            } catch {
                Darwin.close(opened.fd)
                throw error
            }
        case .addRoute(let interface, let subnet):
            try HostNetCommands.addRoute(interface: interface, subnet: subnet)
            routes[interface, default: []].insert(subnet)
            return nil
        case .teardown(let interface):
            for subnet in routes.removeValue(forKey: interface) ?? [] {
                try? HostNetCommands.deleteRoute(subnet: subnet)
            }
            return nil
        }
    }
}
