import Darwin
import Foundation

/// Opens a kernel `utun` device. Signed `mackerd` gets `EPERM` on macOS 26; the root helper
/// calls this and passes the fd with `SCM_RIGHTS`.
public enum UtunControl: Sendable {
    /// `CTLIOCGINFO`: resolve a kernel control name to its id.
    private static let ctlIOCGInfo = UInt(0xc064_4e03)
    /// `UTUN_OPT_IFNAME`: read back the assigned `utunN` name.
    private static let optIfName: Int32 = 2

    public static func open() throws -> (fd: Int32, name: String) {
        let sock = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard sock >= 0 else {
            throw HelperError.unavailable("failed to open utun control socket")
        }
        var info = ctl_info()
        let control = "com.apple.net.utun_control"
        withUnsafeMutableBytes(of: &info.ctl_name) { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            _ = control.withCString { strcpy(base, $0) }
        }
        guard ioctl(sock, Self.ctlIOCGInfo, &info) == 0 else {
            Darwin.close(sock)
            throw HelperError.unavailable("utun CTLIOCGINFO failed")
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
            let detail = String(cString: strerror(errno))
            Darwin.close(sock)
            throw HelperError.unavailable("utun connect failed: \(detail)")
        }
        var ifname = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var len = socklen_t(IFNAMSIZ)
        guard getsockopt(sock, SYSPROTO_CONTROL, Self.optIfName, &ifname, &len) == 0 else {
            Darwin.close(sock)
            throw HelperError.unavailable("utun UTUN_OPT_IFNAME failed")
        }
        return (sock, String(cString: ifname))
    }
}
