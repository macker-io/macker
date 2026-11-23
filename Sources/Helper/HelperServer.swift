import Darwin
import Foundation
import HelperSupport

enum HelperServer {
    /// Hard cap on simultaneous client handlers (descriptor + thread budget).
    static let maxConcurrentConnections = 8
    /// Absolute monotonic budget to finish reading one request line.
    static let requestReadTimeoutSeconds: TimeInterval = 5
    /// Bounds `write` / `sendmsg` on the accepted client socket.
    static let responseSendTimeoutSeconds: TimeInterval = 5

    static func run() throws -> Never {
        guard geteuid() == 0 else {
            throw HelperError.notRoot
        }
        let hostNet = HostNet()
        let mutationLock = NSLock()
        let admission = HelperConnectionAdmission(limit: maxConcurrentConnections)
        let workQueue = DispatchQueue(
            label: "io.macker.helper.connections",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let fd = try HelperChannel.bindListen(socketPath: HelperPaths.socketPath)
        log("listening on \(HelperPaths.socketPath)")
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                continue
            }
            guard admission.tryAcquire() else {
                log("rejecting connection: at capacity (\(maxConcurrentConnections))")
                Darwin.close(client)
                continue
            }
            // Absolute budget starts at admission, before queue scheduling delay.
            let readDeadline = HelperReadDeadline.after(requestReadTimeoutSeconds)
            do {
                try HelperChannel.setSendTimeout(client, seconds: responseSendTimeoutSeconds)
            } catch {
                log(error.localizedDescription)
                Darwin.close(client)
                admission.release()
                continue
            }
            workQueue.async {
                defer {
                    Darwin.close(client)
                    admission.release()
                }
                handle(
                    client,
                    hostNet: hostNet,
                    mutationLock: mutationLock,
                    readDeadline: readDeadline
                )
            }
        }
    }

    private static func handle(
        _ fd: Int32,
        hostNet: HostNet,
        mutationLock: NSLock,
        readDeadline: HelperReadDeadline
    ) {
        var pendingFD: Int32 = -1
        defer {
            if pendingFD >= 0 { Darwin.close(pendingFD) }
        }
        let response: HelperResponse
        do {
            let data = try HelperChannel.readLine(fd, deadline: readDeadline)
            let command = try JSONDecoder().decode(HelperRequest.self, from: data).validated()
            if command != .ping {
                try authorize(uid: HelperChannel.peerUID(fd))
            }
            let attached: (fd: Int32, name: String)?
            if command == .ping {
                attached = try hostNet.apply(command)
            } else {
                // Serialize privileged network mutations; reads/admission stay concurrent.
                mutationLock.lock()
                defer { mutationLock.unlock() }
                attached = try hostNet.apply(command)
            }
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
        case .addAddress: return HelperOperation.addAddress.rawValue
        case .teardown: return HelperOperation.teardown.rawValue
        }
    }

    private static func interface(of command: ValidatedHelperRequest) -> String? {
        switch command {
        case .addRoute(let interface, _), .teardown(let interface):
            return interface
        case let .addAddress(interface, _, _, _):
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
