import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import Virtualization

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
    private let queue = DispatchQueue(label: "io.macker.net.link")
    private var rx = [UInt8](repeating: 0, count: rxCapacity)
    private var txEthernet = [UInt8](repeating: 0, count: Ethernet.headerLength)

    init(containerID: String, ipv4: CIDRv4, gateway: IPv4Address, mac: MACAddress) throws {
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
            macAddress: mac,
            fileHandle: guestHandle
        )
        let dst = mac.bytes
        let src = NetworkGateway.gatewayMAC.bytes
        for i in 0..<6 {
            txEthernet[i] = dst[i]
            txEthernet[6 + i] = src[i]
        }
        txEthernet[12] = UInt8(Ethernet.typeIPv4 >> 8)
        txEthernet[13] = UInt8(Ethernet.typeIPv4 & 0xff)
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
        frame.withUnsafeBytes { raw in
            _ = Darwin.send(hostHandle.fileDescriptor, raw.baseAddress, frame.count, MSG_DONTWAIT)
        }
    }

    /// Ethernet wrap + send without concatenating into a new `Data`.
    func sendIPv4(_ packet: UnsafeRawBufferPointer) {
        guard let payload = packet.baseAddress, packet.count > 0 else { return }
        let fd = hostHandle.fileDescriptor
        txEthernet.withUnsafeMutableBytes { eth in
            guard let ethBase = eth.baseAddress else { return }
            var iovs = [
                iovec(iov_base: ethBase, iov_len: Ethernet.headerLength),
                iovec(iov_base: UnsafeMutableRawPointer(mutating: payload), iov_len: packet.count),
            ]
            iovs.withUnsafeMutableBufferPointer { buf in
                var msg = msghdr()
                msg.msg_iov = buf.baseAddress
                msg.msg_iovlen = 2
                _ = sendmsg(fd, &msg, MSG_DONTWAIT)
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
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
    let macAddress: MACAddress?
    let mtu: UInt32 = UInt32(FileHandleLink.virtioMTU)
    private let fileHandle: FileHandle

    init(ipv4Address: CIDRv4, ipv4Gateway: IPv4Address?, macAddress: MACAddress?, fileHandle: FileHandle) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
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
