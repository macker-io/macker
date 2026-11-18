import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import Virtualization
import os

/// Bounded datagram TX queue shared by virtio-net and utun.
struct PacketTxQueue {
    var pending: [Data] = []
    var bytes = 0
    static let limit = 4 * 1024 * 1024

    var isEmpty: Bool { pending.isEmpty }
    var isSaturated: Bool { bytes >= Self.limit }
    var shouldResumeReads: Bool { bytes < Self.limit / 2 }

    mutating func append(_ frame: Data) {
        guard !isSaturated else { return }
        pending.append(frame)
        bytes += frame.count
    }

    mutating func popFirst() {
        guard !pending.isEmpty else { return }
        let dropped = pending.removeFirst()
        bytes = max(0, bytes - dropped.count)
    }
}

/// virtio-net attached with a datagram socketpair. The host end is read by ``BridgeDataplane``.
///
/// Apple requires `SO_RCVBUF` ≥ 2× (ideally 4×) `SO_SNDBUF` on the VZ-facing socket, and
/// allows MTU up to 65535.
final class FileHandleLink: @unchecked Sendable {
    static let virtioMTU = 65535
    private static let rxCapacity = virtioMTU + Ethernet.headerLength + 64

    let containerID: String
    let guestMAC: MACAddress
    let interface: FileHandleInterface
    private let hostHandle: FileHandle
    private let guestHandle: FileHandle
    private var source: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private let queue = DispatchQueue(label: "io.macker.net.link")
    private var rx = [UInt8](repeating: 0, count: rxCapacity)
    private let ethernetHeader: [UInt8]
    private let ethernetHeaderIPv6: [UInt8]
    private let tx = OSAllocatedUnfairLock(initialState: PacketTxQueue())
    private var writesResumed = false
    private var readsPaused = false

    init(
        containerID: String,
        ipv4: CIDRv4,
        gateway: IPv4Address,
        ipv6: CIDRv6? = nil,
        ipv6Gateway: IPv6Address? = nil,
        mac: MACAddress
    ) throws {
        var fds: [Int32] = [0, 0]
        let pair = fds.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_DGRAM, 0, buffer.baseAddress)
        }
        guard pair == 0 else {
            throw EngineError.runtimeUnavailable("failed to create virtio socketpair: \(String(cString: strerror(errno)))")
        }
        let hostFD = fds[0]
        let guestFD = fds[1]
        Self.configureSocket(hostFD)
        Self.configureSocket(guestFD)
        self.containerID = containerID
        self.guestMAC = mac
        self.hostHandle = FileHandle(fileDescriptor: hostFD, closeOnDealloc: true)
        self.guestHandle = FileHandle(fileDescriptor: guestFD, closeOnDealloc: true)
        self.interface = FileHandleInterface(
            ipv4Address: ipv4,
            ipv4Gateway: gateway,
            ipv6Address: ipv6,
            ipv6Gateway: ipv6Gateway,
            macAddress: mac,
            fileHandle: guestHandle
        )
        var header = [UInt8](repeating: 0, count: Ethernet.headerLength)
        let dst = mac.bytes
        let src = NetworkGateway.gatewayMAC.bytes
        for index in 0..<6 {
            header[index] = dst[index]
            header[6 + index] = src[index]
        }
        var header6 = header
        header[12] = UInt8(Ethernet.typeIPv4 >> 8)
        header[13] = UInt8(Ethernet.typeIPv4 & 0xff)
        header6[12] = UInt8(Ethernet.typeIPv6 >> 8)
        header6[13] = UInt8(Ethernet.typeIPv6 & 0xff)
        self.ethernetHeader = header
        self.ethernetHeaderIPv6 = header6
    }

    func start(_ onFrame: @escaping (UnsafeRawBufferPointer) -> Void) {
        let fd = hostHandle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let n = self.rx.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.recv(fd, base, raw.count, MSG_DONTWAIT)
                }
                guard n > 0 else { return }
                self.rx.withUnsafeBytes { raw in
                    onFrame(UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
                }
            }
        }
        self.source = source
        source.resume()
    }

    func send(_ frame: Data) {
        if enqueueIfBusy(frame) {
            armWrite()
            return
        }
        if sendFrame(frame) { return }
        enqueue(frame)
    }

    /// Ethernet wrap + send without concatenating into a new `Data` on the success path.
    func sendIPv4(_ packet: UnsafeRawBufferPointer) {
        sendPacket(packet, header: ethernetHeader)
    }

    func sendIPv6(_ packet: UnsafeRawBufferPointer) {
        sendPacket(packet, header: ethernetHeaderIPv6)
    }

    private func sendPacket(_ packet: UnsafeRawBufferPointer, header: [UInt8]) {
        guard packet.count > 0 else { return }
        if enqueueIfBusy(nil) {
            enqueue(copyFrame(packet, header: header))
            return
        }
        if sendPacketNow(packet, header: header) { return }
        enqueue(copyFrame(packet, header: header))
    }

    func stop() {
        source?.cancel()
        source = nil
        writeSource?.cancel()
        writeSource = nil
        writesResumed = false
        readsPaused = false
        tx.withLock { $0 = PacketTxQueue() }
    }

    /// Guest-end datagram (the VZ side of the socketpair). Tests use this to observe TX.
    func recvGuest() -> Data? {
        var buffer = [UInt8](repeating: 0, count: Self.rxCapacity)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.recv(guestHandle.fileDescriptor, base, raw.count, MSG_DONTWAIT)
        }
        guard n > 0 else { return nil }
        return Data(buffer.prefix(n))
    }

    deinit {
        stop()
    }

    private func enqueueIfBusy(_ frame: Data?) -> Bool {
        tx.withLock { state in
            guard !state.isEmpty else { return false }
            if let frame {
                state.append(frame)
            }
            return true
        }
    }

    private func enqueue(_ frame: Data) {
        tx.withLock { $0.append(frame) }
        armWrite()
    }

    private func sendFrame(_ frame: Data) -> Bool {
        frame.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            let sent = Darwin.send(hostHandle.fileDescriptor, base, frame.count, MSG_DONTWAIT)
            if sent >= 0 { return true }
            return errno != EAGAIN && errno != EWOULDBLOCK
        }
    }

    private func sendPacketNow(_ packet: UnsafeRawBufferPointer, header: [UInt8]) -> Bool {
        guard let payload = packet.baseAddress else { return true }
        let fd = hostHandle.fileDescriptor
        return header.withUnsafeBytes { eth -> Bool in
            guard let ethBase = eth.baseAddress else { return true }
            var iovs = [
                iovec(iov_base: UnsafeMutableRawPointer(mutating: ethBase), iov_len: Ethernet.headerLength),
                iovec(iov_base: UnsafeMutableRawPointer(mutating: payload), iov_len: packet.count),
            ]
            return iovs.withUnsafeMutableBufferPointer { buf -> Bool in
                var msg = msghdr()
                msg.msg_iov = buf.baseAddress
                msg.msg_iovlen = 2
                let sent = sendmsg(fd, &msg, MSG_DONTWAIT)
                if sent >= 0 { return true }
                return errno != EAGAIN && errno != EWOULDBLOCK
            }
        }
    }

    private func copyFrame(_ packet: UnsafeRawBufferPointer, header: [UInt8]) -> Data {
        var frame = Data(count: Ethernet.headerLength + packet.count)
        frame.withUnsafeMutableBytes { dest in
            guard let base = dest.baseAddress else { return }
            header.withUnsafeBytes { eth in
                if let ethBase = eth.baseAddress {
                    base.copyMemory(from: ethBase, byteCount: Ethernet.headerLength)
                }
            }
            if let payload = packet.baseAddress {
                base.advanced(by: Ethernet.headerLength).copyMemory(from: payload, byteCount: packet.count)
            }
        }
        return frame
    }

    private func armWrite() {
        queue.async { self.drainTx() }
    }

    private func drainTx() {
        while true {
            let snapshot = tx.withLock { ($0.pending.first, $0.bytes) }
            if snapshot.1 >= PacketTxQueue.limit {
                pauseReadsIfNeeded()
            }
            guard let frame = snapshot.0 else {
                suspendWrites()
                resumeReadsIfNeeded()
                return
            }
            if !sendFrame(frame) {
                resumeWrites()
                return
            }
            tx.withLock { $0.popFirst() }
        }
    }

    private func resumeWrites() {
        if writeSource == nil {
            let fd = hostHandle.fileDescriptor
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

    /// Apple: RCVBUF should be 4× SNDBUF on the datagram socket passed to VZ.
    private static func configureSocket(_ fd: Int32) {
        var snd = Int32(2 * 1024 * 1024)
        var rcv = Int32(8 * 1024 * 1024)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}

struct FileHandleInterface: Interface, VZInterface, @unchecked Sendable {
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address?
    let ipv6Address: CIDRv6?
    let ipv6Gateway: IPv6Address?
    let macAddress: MACAddress?
    let mtu: UInt32 = UInt32(FileHandleLink.virtioMTU)
    private let fileHandle: FileHandle

    init(
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address?,
        ipv6Address: CIDRv6? = nil,
        ipv6Gateway: IPv6Address? = nil,
        macAddress: MACAddress?,
        fileHandle: FileHandle
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Address = ipv6Address
        self.ipv6Gateway = ipv6Gateway
        self.macAddress = macAddress
        self.fileHandle = fileHandle
    }

    func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress, let mac = VZMACAddress(string: macAddress.description) {
            config.macAddress = mac
        }
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
        attachment.maximumTransmissionUnit = FileHandleLink.virtioMTU
        config.attachment = attachment
        return config
    }
}
