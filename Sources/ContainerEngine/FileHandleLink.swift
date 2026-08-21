import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import Virtualization

/// virtio-net attached with a datagram socketpair. The host end is read by ``NetworkGateway``.
final class FileHandleLink: @unchecked Sendable {
    let containerID: String
    let guestMAC: MACAddress
    let interface: FileHandleInterface
    private let hostHandle: FileHandle
    private let guestHandle: FileHandle
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.macker.net.link")

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
        var buf = Int32(1 << 20)
        setsockopt(hostFD, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(guestFD, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
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
    }

    func start(_ onFrame: @escaping @Sendable (Data) -> Void) {
        let fd = hostHandle.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return }
            onFrame(Data(buffer[0..<n]))
        }
        self.source = source
        source.resume()
    }

    func send(_ frame: Data) {
        frame.withUnsafeBytes { raw in
            _ = Darwin.send(hostHandle.fileDescriptor, raw.baseAddress, frame.count, 0)
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}

struct FileHandleInterface: Interface, VZInterface, @unchecked Sendable {
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address?
    let macAddress: MACAddress?
    let mtu: UInt32 = 1500
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
        config.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fileHandle)
        return config
    }
}
