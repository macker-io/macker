import Darwin
import Foundation

/// Host-side utun, the `docker0` equivalent: gives the Mac a route into container subnets.
///
/// `open` works unprivileged, but `configure` / `addRoute` shell out to `ifconfig` and `route`,
/// which need root. Callers treat failure as "no host route" and keep working. This device is
/// also the base for moving outbound NAT and `-p` into the kernel (utun + `pf`) instead of
/// terminating TCP in ``GatewayNAT``.
final class UtunDevice: @unchecked Sendable {
    /// `CTLIOCGINFO`: resolve a kernel control name to its id.
    private static let ctlIOCGInfo = UInt(0xc064_4e03)
    /// `UTUN_OPT_IFNAME`: read back the assigned `utunN` name.
    private static let optIfName: Int32 = 2
    /// utun prepends a 4-byte address family to every packet.
    private static let protocolHeader = 4

    private(set) var fd: Int32 = -1
    private(set) var name = ""
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.macker.net.utun")

    func open() throws {
        let sock = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard sock >= 0 else {
            throw EngineError.runtimeUnavailable("failed to open utun control socket")
        }
        var info = ctl_info()
        let control = "com.apple.net.utun_control"
        withUnsafeMutableBytes(of: &info.ctl_name) { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            _ = control.withCString { strcpy(base, $0) }
        }
        guard ioctl(sock, Self.ctlIOCGInfo, &info) == 0 else {
            close(sock)
            throw EngineError.runtimeUnavailable("utun CTLIOCGINFO failed")
        }
        var addr = sockaddr_ctl()
        addr.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        addr.sc_family = UInt8(AF_SYSTEM)
        addr.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        addr.sc_id = info.ctl_id
        addr.sc_unit = 0
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        guard connected == 0 else {
            close(sock)
            throw EngineError.runtimeUnavailable("utun connect failed: \(String(cString: strerror(errno)))")
        }
        var ifname = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var len = socklen_t(IFNAMSIZ)
        guard getsockopt(sock, SYSPROTO_CONTROL, Self.optIfName, &ifname, &len) == 0 else {
            close(sock)
            throw EngineError.runtimeUnavailable("utun UTUN_OPT_IFNAME failed")
        }
        fd = sock
        name = String(cString: ifname)
    }

    func configure(address: String, peer: String, prefix: Int) throws {
        guard !name.isEmpty else {
            throw EngineError.runtimeUnavailable("utun is not open")
        }
        let mask = prefixMask(prefix)
        let ifconfig = Process()
        ifconfig.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        ifconfig.arguments = [name, "inet", address, peer, "netmask", mask, "up"]
        try ifconfig.run()
        ifconfig.waitUntilExit()
        guard ifconfig.terminationStatus == 0 else {
            throw EngineError.runtimeUnavailable(
                "ifconfig \(name) inet \(address) \(peer) netmask \(mask) failed"
            )
        }
    }

    func addRoute(subnet: String) {
        guard !name.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "add", "-net", subnet, "-interface", name]
        try? process.run()
        process.waitUntilExit()
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
            close(fd)
            fd = -1
        }
    }

    private func prefixMask(_ prefix: Int) -> String {
        let bits = prefix < 0 ? 0 : min(prefix, 32)
        let mask = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return "\((mask >> 24) & 0xff).\((mask >> 16) & 0xff).\((mask >> 8) & 0xff).\(mask & 0xff)"
    }
}
