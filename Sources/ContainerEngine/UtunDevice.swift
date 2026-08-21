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

    private(set) var fd: Int32 = -1
    private(set) var name = ""
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.macker.net.utun")

    func adopt(fd: Int32, name: String) {
        closeDevice()
        self.fd = fd
        self.name = name
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

    func start(_ onPacket: @escaping @Sendable (Data) -> Void) {
        let fd = self.fd
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2048)
            let n = read(fd, &buffer, buffer.count)
            guard n > Self.protocolHeader else { return }
            onPacket(Data(buffer[Self.protocolHeader..<n]))
        }
        self.source = source
        source.resume()
    }

    func writeIP(_ packet: Data) {
        guard fd >= 0 else { return }
        var framed = Data([0, 0, 0, UInt8(AF_INET)])
        framed.append(packet)
        framed.withUnsafeBytes { raw in
            _ = Darwin.write(fd, raw.baseAddress, framed.count)
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
}
