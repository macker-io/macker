import Darwin
import Foundation

/// Absolute monotonic deadline for a helper request read (not an inactivity/idle timer).
/// Built from `DispatchTime`, which is mach continuous time on Apple platforms.
public struct HelperReadDeadline: Sendable {
    public let deadline: DispatchTime

    public init(deadline: DispatchTime) {
        self.deadline = deadline
    }

    public static func after(_ seconds: TimeInterval) -> HelperReadDeadline {
        let millis = max(1, Int((seconds * 1_000).rounded(.up)))
        return HelperReadDeadline(deadline: DispatchTime.now() + .milliseconds(millis))
    }

    public var isExpired: Bool {
        DispatchTime.now() >= deadline
    }

    /// Remaining wait budget in milliseconds; `0` when expired.
    public var remainingMilliseconds: Int32 {
        let now = DispatchTime.now()
        if now >= deadline { return 0 }
        let nanos = deadline.uptimeNanoseconds &- now.uptimeNanoseconds
        let millis = nanos / 1_000_000
        if millis == 0 { return 1 }
        if millis > UInt64(Int32.max) { return Int32.max }
        return Int32(millis)
    }
}

public enum HelperChannel {
    public static func connect(socketPath: String, timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperError.unavailable("failed to create UNIX socket")
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        do {
            try fill(&addr, path: socketPath)
        } catch {
            Darwin.close(fd)
            throw error
        }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw HelperError.unavailable("cannot connect to \(socketPath)")
        }
        return fd
    }

    public static func bindListen(socketPath: String) throws -> Int32 {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperError.unavailable("failed to create UNIX socket")
        }
        var addr = sockaddr_un()
        do {
            try fill(&addr, path: socketPath)
        } catch {
            Darwin.close(fd)
            throw error
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw HelperError.unavailable("failed to bind \(socketPath)")
        }
        guard listen(fd, 16) == 0 else {
            Darwin.close(fd)
            unlink(socketPath)
            throw HelperError.unavailable("failed to listen on \(socketPath)")
        }
        _ = chmod(socketPath, 0o666)
        return fd
    }

    public static func writeLine(_ fd: Int32, _ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { buffer in
            var written = 0
            let total = buffer.count
            while written < total {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), total - written)
                if n <= 0 {
                    throw HelperError.unavailable("helper socket write failed")
                }
                written += n
            }
        }
    }

    public static func readLine(_ fd: Int32, limit: Int = 65_536) throws -> Data {
        try readLine(fd, limit: limit, deadline: nil)
    }

    /// Reads one newline-terminated line, optionally bound by an absolute monotonic deadline.
    /// When `deadline` is set, each wait uses the remaining time until that fixed deadline
    /// (trickled bytes do not extend the budget).
    public static func readLine(
        _ fd: Int32,
        limit: Int = 65_536,
        deadline: HelperReadDeadline?
    ) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < limit {
            if let deadline {
                let remaining = deadline.remainingMilliseconds
                if remaining <= 0 {
                    throw HelperError.unavailable("helper request read timed out")
                }
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollFD, 1, remaining)
                if ready == 0 {
                    throw HelperError.unavailable("helper request read timed out")
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw HelperError.unavailable("helper socket read failed")
                }
                if (pollFD.revents & Int16(POLLIN)) == 0 {
                    if (pollFD.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                        throw HelperError.unavailable("helper closed the connection")
                    }
                    if deadline.isExpired {
                        throw HelperError.unavailable("helper request read timed out")
                    }
                    continue
                }
            }
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 {
                throw HelperError.unavailable("helper closed the connection")
            }
            if n < 0 {
                if errno == EINTR { continue }
                if let deadline, deadline.isExpired, errno == EAGAIN || errno == EWOULDBLOCK {
                    throw HelperError.unavailable("helper request read timed out")
                }
                throw HelperError.unavailable("helper socket read failed")
            }
            if byte == 0x0A {
                // Recheck absolute deadline after the successful read so a
                // last-byte race cannot report success past the budget.
                if let deadline, deadline.isExpired {
                    throw HelperError.unavailable("helper request read timed out")
                }
                return data
            }
            data.append(byte)
        }
        throw HelperError.invalidRequest("helper request too large")
    }

    /// Bounds blocking writes / `sendmsg` on an accepted helper client socket.
    /// Setup must succeed; a missing send timeout leaves response paths unbounded.
    public static func setSendTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        let millis = max(1, Int((seconds * 1_000).rounded(.up)))
        var timeout = timeval(
            tv_sec: millis / 1_000,
            tv_usec: Int32((millis % 1_000) * 1_000)
        )
        let rc = setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard rc == 0 else {
            throw HelperError.unavailable("failed to set helper socket send timeout")
        }
    }

    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    public static func sendDescriptor(_ payloadFD: Int32, over socketFD: Int32) throws {
        try withAncillaryMessage(payloadFD: payloadFD) { msg, payload in
            guard let cmsg = firstCMsg(&msg) else {
                throw HelperError.unavailable("CMSG_FIRSTHDR failed")
            }
            cmsg.pointee.cmsg_level = SOL_SOCKET
            cmsg.pointee.cmsg_type = SCM_RIGHTS
            cmsg.pointee.cmsg_len = socklen_t(cmsgLen(MemoryLayout<Int32>.size))
            memcpy(cmsgData(cmsg), payload, MemoryLayout<Int32>.size)
            guard sendmsg(socketFD, &msg, 0) >= 0 else {
                throw HelperError.unavailable("sendmsg failed")
            }
        }
    }

    public static func receiveDescriptor(from socketFD: Int32) throws -> Int32 {
        try withAncillaryMessage(payloadFD: -1) { msg, payload in
            guard recvmsg(socketFD, &msg, 0) >= 0 else {
                throw HelperError.unavailable("recvmsg failed")
            }
            guard let cmsg = firstCMsg(&msg),
                cmsg.pointee.cmsg_level == SOL_SOCKET,
                cmsg.pointee.cmsg_type == SCM_RIGHTS
            else {
                throw HelperError.unavailable("helper did not pass a utun fd")
            }
            memcpy(payload, cmsgData(cmsg), MemoryLayout<Int32>.size)
            let fd = payload.pointee
            guard fd >= 0 else {
                throw HelperError.unavailable("invalid utun fd from helper")
            }
            return fd
        }
    }

    private static func align32(_ n: Int) -> Int { (n + 3) & ~3 }

    private static func cmsgSpace(_ length: Int) -> Int {
        align32(MemoryLayout<cmsghdr>.size) + align32(length)
    }

    private static func cmsgLen(_ length: Int) -> Int {
        align32(MemoryLayout<cmsghdr>.size) + length
    }

    private static func firstCMsg(_ msg: inout msghdr) -> UnsafeMutablePointer<cmsghdr>? {
        guard msg.msg_controllen >= MemoryLayout<cmsghdr>.size, let control = msg.msg_control else {
            return nil
        }
        return control.assumingMemoryBound(to: cmsghdr.self)
    }

    private static func cmsgData(_ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(cmsg) + align32(MemoryLayout<cmsghdr>.size)
    }

    private static func withAncillaryMessage<T>(
        payloadFD: Int32,
        body: (inout msghdr, UnsafeMutablePointer<Int32>) throws -> T
    ) throws -> T {
        var payload = payloadFD
        var dummy: CChar = 0
        let controlSize = cmsgSpace(MemoryLayout<Int32>.size)
        let control = UnsafeMutableRawPointer.allocate(
            byteCount: controlSize,
            alignment: MemoryLayout<cmsghdr>.alignment
        )
        defer { control.deallocate() }
        control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
        return try withUnsafeMutablePointer(to: &dummy) { dummyPtr in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(dummyPtr), iov_len: 1)
            return try withUnsafeMutablePointer(to: &iov) { iovPtr in
                var msg = msghdr(
                    msg_name: nil,
                    msg_namelen: 0,
                    msg_iov: iovPtr,
                    msg_iovlen: 1,
                    msg_control: control,
                    msg_controllen: socklen_t(controlSize),
                    msg_flags: 0
                )
                return try withUnsafeMutablePointer(to: &payload) { payloadPtr in
                    try body(&msg, payloadPtr)
                }
            }
        }
    }

    private static func fill(_ addr: inout sockaddr_un, path: String) throws {
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= pathLimit else {
            throw HelperError.unavailable("socket path exceeds UNIX address limit")
        }
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyBytes(from: UnsafeRawBufferPointer(start: src, count: path.utf8.count + 1))
            }
        }
    }
}
