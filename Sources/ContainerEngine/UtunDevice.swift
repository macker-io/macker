import Darwin
import Foundation
import HelperSupport

/// Host-side utun, the `docker0` equivalent: gives the Mac a route into container subnets.
///
/// A signed `mackerd` cannot `open` utun on macOS 26 (`EPERM`). The root helper opens the
/// device and passes the fd; this type owns packet I/O. Address and routes still go through
/// the helper (or in-process `ifconfig` / `route` when this process is already root).
final class UtunDevice: @unchecked Sendable {
    /// utun prepends a 4-byte address family to every packet.
    private static let protocolHeader = 4
    private static let rxCapacity = 65535 + protocolHeader
    private static let afInetPrefix: [UInt8] = [0, 0, 0, UInt8(AF_INET)]

    private(set) var fd: Int32 = -1
    private(set) var name = ""
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.macker.net.utun")
    private var rx = [UInt8](repeating: 0, count: rxCapacity)

    func adopt(fd: Int32, name: String) {
        closeDevice()
        self.fd = fd
        self.name = name
        Self.setNonblocking(fd)
    }

    func open() throws {
        do {
            let opened = try UtunControl.open()
            adopt(fd: opened.fd, name: opened.name)
        } catch {
            throw EngineError.runtimeUnavailable(error.localizedDescription)
        }
    }

    func configure(address: String, peer: String, prefix: Int) throws {
        guard !name.isEmpty else {
            throw EngineError.runtimeUnavailable("utun is not open")
        }
        do {
            try HostNetCommands.configure(interface: name, address: address, peer: peer, prefix: prefix)
        } catch {
            throw EngineError.runtimeUnavailable(error.localizedDescription)
        }
    }

    func addRoute(subnet: String) {
        guard !name.isEmpty else { return }
        try? HostNetCommands.addRoute(interface: name, subnet: subnet)
    }

    func start(_ onPacket: @escaping (UnsafeRawBufferPointer) -> Void) {
        let fd = self.fd
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let n = self.rx.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(fd, base, raw.count)
                }
                if n < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    return
                }
                if n == 0 { return }
                if n <= Self.protocolHeader { continue }
                self.rx.withUnsafeBytes { raw in
                    onPacket(
                        UnsafeRawBufferPointer(
                            start: raw.baseAddress.map { $0 + Self.protocolHeader },
                            count: n - Self.protocolHeader
                        )
                    )
                }
            }
        }
        self.source = source
        source.resume()
    }

    func writeIP(_ packet: Data) {
        packet.withUnsafeBytes { writeIP($0) }
    }

    func writeIP(_ packet: UnsafeRawBufferPointer) {
        guard fd >= 0, let payload = packet.baseAddress, packet.count > 0 else { return }
        var header = Self.afInetPrefix
        header.withUnsafeMutableBytes { af in
            guard let afBase = af.baseAddress else { return }
            let iovs = [
                iovec(iov_base: afBase, iov_len: Self.protocolHeader),
                iovec(iov_base: UnsafeMutableRawPointer(mutating: payload), iov_len: packet.count),
            ]
            iovs.withUnsafeBufferPointer { buf in
                _ = writev(fd, buf.baseAddress, 2)
            }
        }
    }

    func closeDevice() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        name = ""
    }

    private static func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}
