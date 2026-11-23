import ContainerizationExtras
import Foundation
import Testing
import os
@testable import ContainerEngine

@Suite(.serialized)
struct NetworkDataplaneTests {
    @Test func dataplaneForwardsSameNetworkWithoutForwarder() throws {
        let net = EngineNetwork(
            id: "net-a",
            name: "bridge",
            driver: "bridge",
            scope: "local",
            created: Date(),
            labels: [:],
            subnet: "172.17.0.0/16",
            gateway: "172.17.0.1",
            internalNetwork: false,
            builtin: true
        )
        let srcIP = IPv4Address(0xAC11_0002)
        let dstIP = IPv4Address(0xAC11_0003)
        let srcLink = try FileHandleLink(
            containerID: "src",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: IPv4Address(0xAC11_0001),
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dstLink = try FileHandleLink(
            containerID: "dst",
            ipv4: try CIDRv4("172.17.0.3/32"),
            gateway: IPv4Address(0xAC11_0001),
            mac: MACAddress(0x0A00_2700_0003)
        )
        let dataplane = BridgeDataplane()
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "src",
                    containerName: "src",
                    hostname: "src",
                    networkID: net.id,
                    networkName: net.name,
                    ip: srcIP,
                    gateway: IPv4Address(0xAC11_0001),
                    aliases: [],
                    internalNetwork: false
                ),
                NetworkGateway.Record(
                    containerID: "dst",
                    containerName: "dst",
                    hostname: "dst",
                    networkID: net.id,
                    networkName: net.name,
                    ip: dstIP,
                    gateway: IPv4Address(0xAC11_0001),
                    aliases: [],
                    internalNetwork: false
                ),
            ],
            dnsUpstreams: [:],
            links: ["src": srcLink, "dst": dstLink],
            forwarder: nil,
            gateways: [0xAC11_0001]
        )
        let payload = Data("same-net".utf8)
        let datagram = UDPDatagram(srcPort: 40_000, dstPort: 9, payload: payload)
        let packet = IPv4Packet(
            tos: 0,
            id: 1,
            ttl: 64,
            proto: Ethernet.protoUDP,
            src: srcIP,
            dst: dstIP,
            payload: datagram.encode(src: srcIP, dst: dstIP)
        )
        let frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeIPv4,
            payload: packet.encode()
        )
        frame.withUnsafeBytes { dataplane.handleFrame(containerID: "src", frame: $0) }
        let received = try #require(dstLink.recvGuest())
        #expect(IPv4Peek.ethernetType(received) == Ethernet.typeIPv4)
        let ip = try #require(IPv4Peek.ipv4Datagram(fromEthernet: received).flatMap(IPv4Packet.parse))
        #expect(ip.src == srcIP)
        #expect(ip.dst == dstIP)
        #expect(UDPDatagram.parse(ip.payload)?.payload == payload)
    }

    @Test func dataplaneDropsCrossNetworkForward() throws {
        let srcIP = IPv4Address(0xAC11_0002)
        let dstIP = IPv4Address(0xAC12_0002)
        let srcLink = try FileHandleLink(
            containerID: "web",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: IPv4Address(0xAC11_0001),
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dstLink = try FileHandleLink(
            containerID: "db",
            ipv4: try CIDRv4("172.18.0.2/32"),
            gateway: IPv4Address(0xAC12_0001),
            mac: MACAddress(0x0A00_2700_0003)
        )
        let dataplane = BridgeDataplane()
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "web",
                    containerName: "web",
                    hostname: "web",
                    networkID: "net-a",
                    networkName: "bridge",
                    ip: srcIP,
                    gateway: IPv4Address(0xAC11_0001),
                    aliases: [],
                    internalNetwork: false
                ),
                NetworkGateway.Record(
                    containerID: "db",
                    containerName: "db",
                    hostname: "db",
                    networkID: "net-b",
                    networkName: "backend",
                    ip: dstIP,
                    gateway: IPv4Address(0xAC12_0001),
                    aliases: [],
                    internalNetwork: true
                ),
            ],
            dnsUpstreams: [:],
            links: ["web": srcLink, "db": dstLink],
            forwarder: nil,
            gateways: [0xAC11_0001, 0xAC12_0001]
        )
        let datagram = UDPDatagram(srcPort: 40_000, dstPort: 9, payload: Data("x".utf8))
        let packet = IPv4Packet(
            tos: 0,
            id: 1,
            ttl: 64,
            proto: Ethernet.protoUDP,
            src: srcIP,
            dst: dstIP,
            payload: datagram.encode(src: srcIP, dst: dstIP)
        )
        let frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeIPv4,
            payload: packet.encode()
        )
        frame.withUnsafeBytes { dataplane.handleFrame(containerID: "web", frame: $0) }
        #expect(dstLink.recvGuest() == nil)
    }

    @Test func gatewayAclAndDnsStayOnTheSameNetwork() async throws {
        let gateway = NetworkGateway()
        let bridge = EngineNetwork(
            id: "net-a",
            name: "bridge",
            driver: "bridge",
            scope: "local",
            created: Date(),
            labels: [:],
            subnet: "172.17.0.0/16",
            gateway: "172.17.0.1",
            internalNetwork: false,
            builtin: true
        )
        let backend = EngineNetwork(
            id: "net-b",
            name: "backend",
            driver: "bridge",
            scope: "local",
            created: Date(),
            labels: [:],
            subnet: "172.18.0.0/16",
            gateway: "172.18.0.1",
            internalNetwork: true,
            builtin: false
        )
        await gateway.registerNetwork(bridge)
        await gateway.registerNetwork(backend)
        let web = try await gateway.allocate(bridge.id, key: "web:net-a")
        let db = try await gateway.allocate(backend.id, key: "db:net-b")
        await gateway.bind(
            containerID: "web",
            containerName: "web",
            hostname: "web",
            network: bridge,
            ip: web,
            aliases: ["www"]
        )
        await gateway.bind(
            containerID: "db",
            containerName: "db",
            hostname: "db",
            network: backend,
            ip: db,
            aliases: []
        )
        #expect(await gateway.canForward(src: web, dst: db) == false)
        #expect(await gateway.allowsOutbound(src: web))
        #expect(await gateway.allowsOutbound(src: db) == false)
        #expect(await gateway.lookup(name: "web", from: web) == web)
        #expect(await gateway.lookup(name: "www", from: web) == web)
        #expect(await gateway.lookup(name: "db", from: web) == nil)
        #expect(await gateway.lookup(name: "db", from: db) == db)
        let webOnBackend = try await gateway.allocate(backend.id, key: "web:net-b")
        await gateway.bind(
            containerID: "web",
            containerName: "web",
            hostname: "web",
            network: backend,
            ip: webOnBackend,
            aliases: []
        )
        #expect(await gateway.lookup(name: "db", from: web) == db)
        #expect(await gateway.canForward(src: web, dst: db))
        #expect(bridge.gateway == "172.17.0.1")
        #expect(backend.gateway == "172.18.0.1")
    }

    @Test func dataplaneAnswersArpForTheNetworkGateway() throws {
        let gatewayIP = IPv4Address(0xAC11_0001)
        let srcIP = IPv4Address(0xAC11_0002)
        let srcLink = try FileHandleLink(
            containerID: "web",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: gatewayIP,
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dataplane = BridgeDataplane()
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "web",
                    containerName: "web",
                    hostname: "web",
                    networkID: "net-a",
                    networkName: "bridge",
                    ip: srcIP,
                    gateway: gatewayIP,
                    aliases: [],
                    internalNetwork: false
                )
            ],
            dnsUpstreams: [:],
            links: ["web": srcLink],
            forwarder: nil,
            gateways: [gatewayIP.value]
        )
        let request = ARP.reply(
            senderMAC: srcLink.guestMAC,
            senderIP: srcIP,
            targetMAC: MACAddress(0),
            targetIP: gatewayIP
        )
        // who-has: oper=1 in a handmade request frame
        var payload = request
        payload[6] = 0
        payload[7] = 1
        let frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeARP,
            payload: payload
        )
        frame.withUnsafeBytes { dataplane.handleFrame(containerID: "web", frame: $0) }
        let received = try #require(srcLink.recvGuest())
        #expect(IPv4Peek.ethernetType(received) == Ethernet.typeARP)
        let reply = Data(received.dropFirst(Ethernet.headerLength))
        #expect(reply.count >= 28)
        #expect(reply[7] == 2)
        #expect(Array(reply[14..<18]) == gatewayIP.bytes)
        #expect(Array(reply[24..<28]) == srcIP.bytes)
    }

    @Test func echoReplyToGatewayGoesToUtun() throws {
        let gatewayIP = IPv4Address(0xAC11_0001)
        let guestIP = IPv4Address(0xAC11_0002)
        let link = try FileHandleLink(
            containerID: "web",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: gatewayIP,
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dataplane = BridgeDataplane()
        let utun = OSAllocatedUnfairLock<[Data]>(initialState: [])
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "web",
                    containerName: "web",
                    hostname: "web",
                    networkID: "net-a",
                    networkName: "bridge",
                    ip: guestIP,
                    gateway: gatewayIP,
                    aliases: [],
                    internalNetwork: false
                )
            ],
            dnsUpstreams: [:],
            links: ["web": link],
            forwarder: nil,
            gateways: [gatewayIP.value]
        )
        dataplane.setUtunWriter { packet in
            utun.withLock { $0.append(packet) }
        }
        let echoReply = icmpEcho(type: 0, src: guestIP, dst: gatewayIP)
        let frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: link.guestMAC,
            type: Ethernet.typeIPv4,
            payload: echoReply.encode()
        )
        frame.withUnsafeBytes { dataplane.handleFrame(containerID: "web", frame: $0) }
        let captured = utun.withLock { $0 }
        #expect(captured.count == 1)
        let parsed = try #require(captured.first.flatMap(IPv4Packet.parse))
        #expect(parsed.src == guestIP)
        #expect(parsed.dst == gatewayIP)
        #expect(parsed.proto == Ethernet.protoICMP)
        #expect(parsed.payload[0] == 0)
        #expect(link.recvGuest() == nil)
    }

    @Test func echoRequestToGatewayStillRepliesOnVirtio() throws {
        let gatewayIP = IPv4Address(0xAC11_0001)
        let guestIP = IPv4Address(0xAC11_0002)
        let link = try FileHandleLink(
            containerID: "web",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: gatewayIP,
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dataplane = BridgeDataplane()
        let utun = OSAllocatedUnfairLock<[Data]>(initialState: [])
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "web",
                    containerName: "web",
                    hostname: "web",
                    networkID: "net-a",
                    networkName: "bridge",
                    ip: guestIP,
                    gateway: gatewayIP,
                    aliases: [],
                    internalNetwork: false
                )
            ],
            dnsUpstreams: [:],
            links: ["web": link],
            forwarder: nil,
            gateways: [gatewayIP.value]
        )
        dataplane.setUtunWriter { packet in
            utun.withLock { $0.append(packet) }
        }
        let echo = icmpEcho(type: 8, src: guestIP, dst: gatewayIP)
        let frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: link.guestMAC,
            type: Ethernet.typeIPv4,
            payload: echo.encode()
        )
        frame.withUnsafeBytes { dataplane.handleFrame(containerID: "web", frame: $0) }
        #expect(utun.withLock { $0.isEmpty })
        let received = try #require(link.recvGuest())
        let ip = try #require(IPv4Peek.ipv4Datagram(fromEthernet: received).flatMap(IPv4Packet.parse))
        #expect(ip.src == gatewayIP)
        #expect(ip.dst == guestIP)
        #expect(ip.payload[0] == 0)
    }

    @Test func finishChecksumsRestoresZeroedIPv4AndICMP() throws {
        let packet = icmpEcho(type: 8, src: IPv4Address(0xAC11_0002), dst: IPv4Address(0xAC11_0001))
        var encoded = packet.encode()
        let expected = encoded
        encoded[10] = 0
        encoded[11] = 0
        encoded[IPv4Packet.headerLength + 2] = 0
        encoded[IPv4Packet.headerLength + 3] = 0
        IPv4Peek.finishChecksums(&encoded)
        #expect(encoded == expected)
    }

    @Test func utunDeliversHostTcpToTheGuest() throws {
        let gatewayIP = IPv4Address(0xAC11_0001)
        let guestIP = IPv4Address(0xAC11_0002)
        let link = try FileHandleLink(
            containerID: "web",
            ipv4: try CIDRv4("172.17.0.2/32"),
            gateway: gatewayIP,
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dataplane = BridgeDataplane()
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "web",
                    containerName: "web",
                    hostname: "web",
                    networkID: "net-a",
                    networkName: "bridge",
                    ip: guestIP,
                    gateway: gatewayIP,
                    aliases: [],
                    internalNetwork: false
                )
            ],
            dnsUpstreams: [:],
            links: ["web": link],
            forwarder: nil,
            gateways: [gatewayIP.value]
        )
        var syn = Data(count: 20)
        syn[0] = 0x04; syn[1] = 0xd2 // 1234
        syn[2] = 0x00; syn[3] = 0x50 // 80
        syn[12] = 0x50
        syn[13] = TCPSegment.Flags.syn.rawValue
        syn[14] = 0xff; syn[15] = 0xff
        let packet = IPv4Packet(
            tos: 0, id: 1, ttl: 64, proto: Ethernet.protoTCP,
            src: gatewayIP, dst: guestIP, payload: syn
        )
        var encoded = packet.encode()
        encoded[10] = 0
        encoded[11] = 0
        encoded[IPv4Packet.headerLength + 16] = 0
        encoded[IPv4Packet.headerLength + 17] = 0
        encoded.withUnsafeBytes { dataplane.handleUtun($0) }
        let received = try #require(link.recvGuest())
        let datagram = try #require(IPv4Peek.ipv4Datagram(fromEthernet: received))
        #expect(datagram[10] != 0 || datagram[11] != 0)
        let ip = try #require(IPv4Packet.parse(datagram))
        #expect(ip.src == gatewayIP)
        #expect(ip.dst == guestIP)
        #expect(TCPSegment.parse(ip.payload)?.flags.contains(.syn) == true)
    }

    @Test func dataplaneHandlesIPv6NDPAndForwarding() throws {
        var ipam6 = try NetworkIPAMv6(subnet: "fd00:29::/64", gateway: "fd00:29::1")
        let a6 = try ipam6.allocate(id: "a")
        let b6 = try ipam6.allocate(id: "b")
        #expect(a6.description == "fd00:29::2")
        #expect(b6.description == "fd00:29::3")

        let gw6 = try IPv6Address("fd00:29::1")
        let srcLink = try FileHandleLink(
            containerID: "src",
            ipv4: try CIDRv4("172.29.0.2/32"),
            gateway: IPv4Address(0xAC1D_0001),
            ipv6: try CIDRv6("fd00:29::2/64"),
            ipv6Gateway: gw6,
            mac: MACAddress(0x0A00_2700_0002)
        )
        let dstLink = try FileHandleLink(
            containerID: "dst",
            ipv4: try CIDRv4("172.29.0.3/32"),
            gateway: IPv4Address(0xAC1D_0001),
            ipv6: try CIDRv6("fd00:29::3/64"),
            ipv6Gateway: gw6,
            mac: MACAddress(0x0A00_2700_0003)
        )
        let dataplane = BridgeDataplane()
        dataplane.update(
            records: [
                NetworkGateway.Record(
                    containerID: "src",
                    containerName: "src",
                    hostname: "src",
                    networkID: "net-v6",
                    networkName: "v6net",
                    ip: IPv4Address(0xAC1D_0002),
                    gateway: IPv4Address(0xAC1D_0001),
                    ip6: a6,
                    gateway6: gw6,
                    aliases: [],
                    internalNetwork: false
                ),
                NetworkGateway.Record(
                    containerID: "dst",
                    containerName: "dst",
                    hostname: "dst",
                    networkID: "net-v6",
                    networkName: "v6net",
                    ip: IPv4Address(0xAC1D_0003),
                    gateway: IPv4Address(0xAC1D_0001),
                    ip6: b6,
                    gateway6: gw6,
                    aliases: [],
                    internalNetwork: false
                ),
            ],
            dnsUpstreams: [:],
            links: ["src": srcLink, "dst": dstLink],
            forwarder: nil,
            gateways: [0xAC1D_0001],
            gateways6: [IPv6Key(gw6)]
        )

        // Same-network IPv6 forwarding
        let v6Packet = IPv6Packet(
            hopLimit: 64,
            nextHeader: Ethernet.protoUDP,
            src: a6,
            dst: b6,
            payload: UDPDatagram(srcPort: 1000, dstPort: 2000, payload: Data("v6".utf8)).encode(src: a6, dst: b6)
        )
        let v6Frame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeIPv6,
            payload: v6Packet.encode()
        )
        v6Frame.withUnsafeBytes { dataplane.handleFrame(containerID: "src", frame: $0) }
        let delivered = try #require(dstLink.recvGuest())
        let parsedEth = try #require(Ethernet.parse(delivered))
        #expect(parsedEth.type == Ethernet.typeIPv6)
        let parsedV6 = try #require(IPv6Packet.parse(parsedEth.payload))
        #expect(parsedV6.src == a6)
        #expect(parsedV6.dst == b6)

        // NDP NS for gateway -> NA reply
        var ns = Data(count: 24)
        ns[0] = NDP.typeNeighborSolicitation
        let targetBytes = gw6.rawBytes
        for i in 0..<16 { ns[8 + i] = targetBytes[i] }
        let nsPacket = IPv6Packet(
            hopLimit: 255,
            nextHeader: Ethernet.protoICMPv6,
            src: a6,
            dst: gw6,
            payload: ns
        )
        let nsFrame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeIPv6,
            payload: nsPacket.encode()
        )
        nsFrame.withUnsafeBytes { dataplane.handleFrame(containerID: "src", frame: $0) }
        let naRaw = try #require(srcLink.recvGuest())
        let naEth = try #require(Ethernet.parse(naRaw))
        #expect(naEth.type == Ethernet.typeIPv6)
        let naV6 = try #require(IPv6Packet.parse(naEth.payload))
        #expect(naV6.nextHeader == Ethernet.protoICMPv6)
        #expect(naV6.payload[0] == NDP.typeNeighborAdvertisement)

        // Router Solicitation (133) -> Router Advertisement (134)
        let rsPayload = Data([NDP.typeRouterSolicitation, 0, 0, 0, 0, 0, 0, 0])
        let rsPacket = IPv6Packet(
            hopLimit: 255,
            nextHeader: Ethernet.protoICMPv6,
            src: a6,
            dst: try IPv6Address("ff02::2"),
            payload: rsPayload
        )
        let rsFrame = Ethernet.frame(
            dst: NetworkGateway.gatewayMAC,
            src: srcLink.guestMAC,
            type: Ethernet.typeIPv6,
            payload: rsPacket.encode()
        )
        rsFrame.withUnsafeBytes { dataplane.handleFrame(containerID: "src", frame: $0) }
        let raRaw = try #require(srcLink.recvGuest())
        let raEth = try #require(Ethernet.parse(raRaw))
        let raV6 = try #require(IPv6Packet.parse(raEth.payload))
        #expect(raV6.payload[0] == NDP.typeRouterAdvertisement)

        // Utun inbound IPv6 packet with zero UDP checksum -> checksum filled + delivered to dstLink
        let utunUDP = UDPDatagram(srcPort: 5000, dstPort: 80, payload: Data("hello6".utf8))
        var zeroSumUDP = Data(count: 8 + utunUDP.payload.count)
        zeroSumUDP[0] = UInt8(5000 >> 8)
        zeroSumUDP[1] = UInt8(5000 & 0xff)
        zeroSumUDP[2] = UInt8(80 >> 8)
        zeroSumUDP[3] = UInt8(80 & 0xff)
        let udpLen = zeroSumUDP.count
        zeroSumUDP[4] = UInt8(udpLen >> 8)
        zeroSumUDP[5] = UInt8(udpLen & 0xff)
        zeroSumUDP.replaceSubrange(8..<udpLen, with: utunUDP.payload)
        let utunPkt = IPv6Packet(
            hopLimit: 64,
            nextHeader: Ethernet.protoUDP,
            src: try IPv6Address("fd00:29::1"),
            dst: b6,
            payload: zeroSumUDP
        ).encode()
        utunPkt.withUnsafeBytes { dataplane.handleUtun($0) }
        let dstRaw = try #require(dstLink.recvGuest())
        let dstEth = try #require(Ethernet.parse(dstRaw))
        let dstV6 = try #require(IPv6Packet.parse(dstEth.payload))
        #expect(dstV6.dst == b6)
        #expect(dstV6.payload[6] != 0 || dstV6.payload[7] != 0)

        // Bracketed IPv6 publish spec
        let binding = try EnginePortBinding.parsePublish("[::1]:8080:80/tcp")
        #expect(binding.hostIP == "::1")
        #expect(binding.hostPort == 8080)
        #expect(binding.containerPort == 80)
        #expect(binding.psDisplay == "[::1]:8080->80/tcp")
    }

    @Test func sourceOwnershipPolicyHelpers() throws {
        #expect(BridgeDataplane.allowsIPv4Source(ownerContainerID: "a", ingressContainerID: "a"))
        #expect(!BridgeDataplane.allowsIPv4Source(ownerContainerID: "a", ingressContainerID: "b"))
        #expect(!BridgeDataplane.allowsIPv4Source(ownerContainerID: nil, ingressContainerID: "a"))

        let assigned = IPv6Key(try IPv6Address("fd00:29::2"))
        let unspecified = IPv6Key(high: 0, low: 0)
        let linkLocal = IPv6Key(try IPv6Address("fe80::1"))
        let unassignedULA = IPv6Key(try IPv6Address("fd00:29::99"))

        #expect(BridgeDataplane.allowsIPv6Source(
            assigned, ownerContainerID: "a", ingressContainerID: "a", isControlSolicitation: false
        ))
        #expect(BridgeDataplane.allowsIPv6Source(
            assigned, ownerContainerID: "a", ingressContainerID: "a", isControlSolicitation: true
        ))
        #expect(!BridgeDataplane.allowsIPv6Source(
            assigned, ownerContainerID: "a", ingressContainerID: "b", isControlSolicitation: true
        ))
        #expect(BridgeDataplane.allowsIPv6Source(
            unspecified, ownerContainerID: nil, ingressContainerID: "a", isControlSolicitation: true
        ))
        #expect(BridgeDataplane.allowsIPv6Source(
            linkLocal, ownerContainerID: nil, ingressContainerID: "a", isControlSolicitation: true
        ))
        #expect(!BridgeDataplane.allowsIPv6Source(
            unspecified, ownerContainerID: nil, ingressContainerID: "a", isControlSolicitation: false
        ))
        #expect(!BridgeDataplane.allowsIPv6Source(
            linkLocal, ownerContainerID: nil, ingressContainerID: "a", isControlSolicitation: false
        ))
        #expect(!BridgeDataplane.allowsIPv6Source(
            unassignedULA, ownerContainerID: nil, ingressContainerID: "a", isControlSolicitation: true
        ))
    }
}

private func icmpEcho(type: UInt8, src: IPv4Address, dst: IPv4Address) -> IPv4Packet {
    var payload = Data(count: 8)
    payload[0] = type
    let sum = Ethernet.checksum(payload)
    payload[2] = UInt8(truncatingIfNeeded: sum >> 8)
    payload[3] = UInt8(truncatingIfNeeded: sum)
    return IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoICMP, src: src, dst: dst, payload: payload)
}
