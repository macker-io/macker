import Darwin
import Foundation

/// Client used by `mackerd` (and `macker helper status`) to talk to the privileged helper.
public enum HelperClient: Sendable {
    public static var isAvailable: Bool {
        (try? ping()) != nil
    }

    @discardableResult
    public static func ping(socketPath: String = HelperPaths.socketPath) throws -> HelperResponse {
        try send(.ping, socketPath: socketPath)
    }

    public static func attach(
        address: String,
        peer: String,
        prefix: Int,
        routes: [String],
        socketPath: String = HelperPaths.socketPath
    ) throws -> (fd: Int32, name: String) {
        let socket = try HelperChannel.connect(socketPath: socketPath, timeoutSeconds: 5)
        defer { Darwin.close(socket) }
        try HelperChannel.writeLine(socket, try JSONEncoder().encode(
            HelperRequest.attach(address: address, peer: peer, prefix: prefix, routes: routes)
        ))
        let response = try decodeResponse(HelperChannel.readLine(socket))
        guard let name = response.interface, HelperNetText.isUtunInterface(name) else {
            throw HelperError.unavailable("helper did not return a utun name")
        }
        let fd = try HelperChannel.receiveDescriptor(from: socket)
        return (fd, name)
    }

    public static func addRoute(
        interface: String,
        subnet: String,
        socketPath: String = HelperPaths.socketPath
    ) throws {
        try send(.addRoute(interface: interface, subnet: subnet), socketPath: socketPath)
    }

    public static func teardown(interface: String, socketPath: String = HelperPaths.socketPath) throws {
        try send(.teardown(interface: interface), socketPath: socketPath)
    }

    @discardableResult
    private static func send(
        _ request: HelperRequest,
        socketPath: String = HelperPaths.socketPath,
        timeoutSeconds: Int = 5
    ) throws -> HelperResponse {
        let fd = try HelperChannel.connect(socketPath: socketPath, timeoutSeconds: timeoutSeconds)
        defer { Darwin.close(fd) }
        let body = try JSONEncoder().encode(request)
        try HelperChannel.writeLine(fd, body)
        let data = try HelperChannel.readLine(fd)
        return try decodeResponse(data)
    }

    private static func decodeResponse(_ data: Data) throws -> HelperResponse {
        let response = try JSONDecoder().decode(HelperResponse.self, from: data)
        guard response.ok else {
            let message = response.error ?? "helper request failed"
            if message == HelperError.unauthorized.errorDescription {
                throw HelperError.unauthorized
            }
            throw HelperError.commandFailed(message)
        }
        return response
    }
}
