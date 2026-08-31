import Darwin
import Foundation
import HelperSupport
import os

/// Host-side utun, the `docker0` equivalent: gives the Mac a route into container subnets.
///
/// A signed `mackerd` cannot `open` utun on macOS 26 (`EPERM`). The root helper opens the
/// device and passes the fd; this type owns packet I/O. Address and routes still go through
/// the helper (or in-process `ifconfig` / `route` when this process is already root).
final class UtunDevice: @unchecked Sendable {
    /// utun prepends a 4-byte address family to every packet.
    private static let protocolHeader = 4
    private static let rxCapacity = 65535 + protocolHeader
    /// Address family in network byte order, as required by utun.
    private static let afInetHeader: [UInt8] = {
        let family = UInt32(AF_INET).bigEndian
        return withUnsafeBytes(of: family, Array.init)
    }()

    private(set) var fd: Int32 = -1
    private(set) var name = ""
    private var source: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private let queue = DispatchQueue(label: "io.macker.net.utun")
    private var rx = [UInt8](repeating: 0, count: rxCapacity)
    private let tx = OSAllocatedUnfairLock(initialState: PacketTxQueue())
    private var writesResumed = false
    private var readsPaused = false

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
        guard fd >= 0, packet.count > 0 else { return }
        let busy = tx.withLock { !$0.pending.isEmpty }
        if busy {
            enqueue(Data(packet))
            return
        }
        if writeIPNow(packet) { return }
        enqueue(Data(packet))
    }

    func closeDevice() {
        source?.cancel()
        source = nil
        writeSource?.cancel()
        writeSource = nil
        writesResumed = false
        readsPaused = false
        tx.withLock { $0 = PacketTxQueue() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        name = ""
    }

    private func enqueue(_ packet: Data) {
        tx.withLock { $0.append(packet) }
        queue.async { self.drainTx() }
    }

    private func writeIPNow(_ packet: UnsafeRawBufferPointer) -> Bool {
        guard let payload = packet.baseAddress, packet.count > 0 else { return true }
        let fd = self.fd
        return Self.afInetHeader.withUnsafeBytes { header -> Bool in
            guard let headerBase = header.baseAddress else { return true }
            var iovs = [
                iovec(iov_base: UnsafeMutableRawPointer(mutating: headerBase), iov_len: Self.protocolHeader),
                iovec(iov_base: UnsafeMutableRawPointer(mutating: payload), iov_len: packet.count),
            ]
            let sent = iovs.withUnsafeMutableBufferPointer { buf in
                Darwin.writev(fd, buf.baseAddress, 2)
            }
            if sent < 0 {
                return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR
            }
            return true
        }
    }

    private func drainTx() {
        while true {
            let snapshot = tx.withLock { ($0.pending.first, $0.bytes) }
            if snapshot.1 >= PacketTxQueue.limit {
                pauseReadsIfNeeded()
            }
            guard let packet = snapshot.0 else {
                suspendWrites()
                resumeReadsIfNeeded()
                return
            }
            let ok = packet.withUnsafeBytes { writeIPNow($0) }
            if !ok {
                resumeWrites()
                return
            }
            tx.withLock { $0.popFirst() }
        }
    }

    private func resumeWrites() {
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drainTx()
            }
            writeSource = source
            source.resume()
            writesResumed = true
            return
        }
        if !writesResumed {
            writeSource?.resume()
            writesResumed = true
        }
    }

    private func suspendWrites() {
        guard writesResumed else { return }
        writeSource?.suspend()
        writesResumed = false
    }

    private func pauseReadsIfNeeded() {
        guard let source, !readsPaused else { return }
        source.suspend()
        readsPaused = true
    }

    private func resumeReadsIfNeeded() {
        let resume = tx.withLock { $0.shouldResumeReads }
        guard resume, readsPaused, let source else { return }
        readsPaused = false
        source.resume()
    }

    private static func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}
