import Darwin
import Foundation
import Testing
@testable import ContainerEngine

struct PortPublisherTests {
    @Test func rejectsUnknownProtocol() async {
        let publisher = PortPublisher()
        await #expect(throws: EngineError.self) {
            _ = try await publisher.publish(
                key: "bad:0",
                hostIP: "127.0.0.1",
                hostPort: 0,
                containerIP: "127.0.0.1",
                containerPort: 9,
                protocolName: "sctp"
            )
        }
    }

    @Test func udpDatagramRoundTrip() async throws {
        try await roundTrip(protocolName: "udp")
    }

    @Test func tcpStreamRoundTrip() async throws {
        try await roundTrip(protocolName: "tcp")
    }

    private func roundTrip(protocolName: String) async throws {
        let echo = try LoopbackEcho(protocolName: protocolName)
        defer { echo.close() }

        let publisher = PortPublisher()
        let key = "\(protocolName)-test:0"
        let hostPort = try await publisher.publish(
            key: key,
            hostIP: "127.0.0.1",
            hostPort: 0,
            containerIP: "127.0.0.1",
            containerPort: echo.port,
            protocolName: protocolName
        )
        defer { publisher.unpublish(keysMatching: key) }

        let payload = Data("macker-\(protocolName)".utf8)
        let reply = try LoopbackEcho.exchange(
            protocolName: protocolName,
            port: hostPort,
            payload: payload
        )
        #expect(reply == payload)
    }
}

/// Loopback echo server plus client, used to exercise the userspace proxy without a MicroVM.
private final class LoopbackEcho: @unchecked Sendable {
    let port: Int
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "io.macker.test.echo")

    init(protocolName: String) throws {
        let udp = protocolName == "udp"
        let fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, udp ? IPPROTO_UDP : IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EPROTONOSUPPORT) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        if !udp {
            guard listen(fd, 1) == 0 else {
                Darwin.close(fd)
                throw POSIXError(.ECONNREFUSED)
            }
        }

        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EINVAL)
        }
        port = Int(UInt16(bigEndian: assigned.sin_port))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            if udp {
                Self.echoDatagram(fd)
            } else {
                Self.acceptStream(fd)
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.source = source
    }

    func close() {
        source.cancel()
    }

    static func exchange(protocolName: String, port: Int, payload: Data) throws -> Data {
        let udp = protocolName == "udp"
        let fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, udp ? IPPROTO_UDP : IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EPROTONOSUPPORT) }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = loopback(port: port)
        let sent: Int
        if udp {
            sent = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == payload.count else { throw POSIXError(.EIO) }
        } else {
            let connected = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            guard payload.withUnsafeBytes({ send(fd, $0.baseAddress, payload.count, 0) }) == payload.count else {
                throw POSIXError(.EIO)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw POSIXError(.ETIMEDOUT) }
        return Data(buffer.prefix(n))
    }

    private static func echoDatagram(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        var peer = sockaddr_in()
        var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &peerLen)
            }
        }
        guard n > 0 else { return }
        _ = withUnsafePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buffer, n, 0, $0, peerLen)
            }
        }
    }

    private static func acceptStream(_ listenFd: Int32) {
        var peer = sockaddr_in()
        var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFd, $0, &peerLen)
            }
        }
        guard client >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let n = recv(client, &buffer, buffer.count, 0)
        if n > 0 {
            _ = send(client, buffer, n, 0)
        }
        Darwin.close(client)
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }
}
