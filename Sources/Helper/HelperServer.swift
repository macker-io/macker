import Darwin
import Foundation
import HelperSupport

enum HelperServer {
    static func run() throws -> Never {
        guard geteuid() == 0 else {
            throw HelperError.notRoot
        }
        let hostNet = HostNet()
        let fd = try HelperChannel.bindListen(socketPath: HelperPaths.socketPath)
        log("listening on \(HelperPaths.socketPath)")
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                continue
            }
            handle(client, hostNet: hostNet)
            Darwin.close(client)
        }
    }

    private static func handle(_ fd: Int32, hostNet: HostNet) {
        var pendingFD: Int32 = -1
        defer {
            if pendingFD >= 0 { Darwin.close(pendingFD) }
        }
        let response: HelperResponse
        do {
            let data = try HelperChannel.readLine(fd)
            let command = try JSONDecoder().decode(HelperRequest.self, from: data).validated()
            if command != .ping {
                try authorize(uid: HelperChannel.peerUID(fd))
            }
            let attached = try hostNet.apply(command)
            if command != .ping {
                log("\(describe(command)) iface=\(attached?.name ?? interface(of: command) ?? "-")")
            }
            if let attached {
                pendingFD = attached.fd
                response = HelperResponse(ok: true, interface: attached.name)
            } else {
                response = command == .ping ? .pong : HelperResponse(ok: true)
            }
        } catch let error as HelperError {
            log(error.localizedDescription)
            response = .failure(error.localizedDescription)
        } catch {
            log(error.localizedDescription)
            response = .failure(error.localizedDescription)
        }
        guard let body = try? JSONEncoder().encode(response) else { return }
        do {
            try HelperChannel.writeLine(fd, body)
            if pendingFD >= 0 {
                try HelperChannel.sendDescriptor(pendingFD, over: fd)
                Darwin.close(pendingFD)
                pendingFD = -1
            }
        } catch {
            log(error.localizedDescription)
        }
    }

    private static func authorize(uid: uid_t?) throws {
        guard let uid, HelperPaths.loadAllowedUIDs().contains(uid) else {
            throw HelperError.unauthorized
        }
    }

    private static func describe(_ command: ValidatedHelperRequest) -> String {
        switch command {
        case .ping: return HelperOperation.ping.rawValue
        case .attach: return HelperOperation.attach.rawValue
        case .addRoute: return HelperOperation.addRoute.rawValue
        case .teardown: return HelperOperation.teardown.rawValue
        }
    }

    private static func interface(of command: ValidatedHelperRequest) -> String? {
        switch command {
        case .addRoute(let interface, _), .teardown(let interface):
            return interface
        case .ping, .attach:
            return nil
        }
    }

    private static func log(_ message: String) {
        fputs("macker-helper: \(message)\n", stderr)
        fflush(stderr)
    }
}
