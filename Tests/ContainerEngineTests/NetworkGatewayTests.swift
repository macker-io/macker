import ContainerizationExtras
import Foundation
import Testing
@testable import ContainerEngine

@Suite(.serialized)
struct NetworkGatewayTests {
    @Test func ipamSkipsNetworkGatewayAndBroadcast() throws {
        var table = try NetworkIPAM(subnet: "172.17.0.0/16")
        let first = try table.allocate(id: "a")
        #expect(first.description == "172.17.0.2")
        try table.reserve(id: "b", ip: IPv4Address(0xAC11_0003))
        let third = try table.allocate(id: "c")
        #expect(third.description == "172.17.0.4")
        table.release(id: "a")
        let reused = try table.allocate(id: "d")
        #expect(reused.description == "172.17.0.2")
        #expect(throws: EngineError.self) {
            try table.reserve(id: "e", ip: IPv4Address(0xAC11_0003)) // taken by "b"
        }
        #expect(throws: EngineError.self) {
            try table.reserve(id: "e", ip: IPv4Address(0xAC11_0001)) // the gateway
        }
        table.release(id: "b")
        try table.reserve(id: "e", ip: IPv4Address(0xAC11_0003))
        #expect(table.address(for: "e")?.description == "172.17.0.3")
    }

    @Test func ipamHonorsIPRangeAndReservedAddresses() throws {
        var table = try NetworkIPAM(
            subnet: "172.17.0.0/16",
            ipRange: "172.17.0.128/25",
            reserved: [IPv4Address(0xAC11_0080)] // 172.17.0.128
        )
        let first = try table.allocate(id: "a")
        #expect(first.description == "172.17.0.129")
        #expect(throws: EngineError.self) {
            try table.reserve(id: "b", ip: IPv4Address(0xAC11_0002)) // outside ip-range
        }
        #expect(throws: EngineError.self) {
            try table.reserve(id: "b", ip: IPv4Address(0xAC11_0080)) // reserved
        }
        try table.reserve(id: "b", ip: IPv4Address(0xAC11_0082)) // 172.17.0.130
        let next = try table.allocate(id: "c")
        #expect(next.description == "172.17.0.131")
    }

    @Test func ipamRejectsIPRangeOutsideSubnet() {
        #expect(throws: EngineError.self) {
            _ = try NetworkIPAM(subnet: "172.17.0.0/16", ipRange: "10.0.0.0/24")
        }
    }

    @Test func dnsAnswersARecords() throws {
        let ip = IPv4Address(0xAC11_0002)
        var query = Data([0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        query.append(contentsOf: [3, 119, 101, 98, 0, 0, 1, 0, 1]) // web A IN
        let question = try #require(GatewayDNS.parseQuery(query))
        #expect(question.name == "web")
        #expect(question.type == 1)
        let answer = GatewayDNS.answer(id: question.id, name: question.name, address: ip)
        #expect(answer[2] & 0x80 != 0)
        #expect(Array(answer.suffix(4)) == ip.bytes)
        let nodata = GatewayDNS.answer(id: question.id, name: question.name, address: nil)
        #expect(nodata[3] & 0x0f == 0)
        let nx = GatewayDNS.answer(id: question.id, name: question.name, address: nil, nxdomain: true)
        #expect(nx[3] & 0x0f == 3)
        var aaaaQuery = Data([0x00, 0x02, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        aaaaQuery.append(contentsOf: [3, 119, 101, 98, 0, 0, 28, 0, 1]) // web AAAA IN
        let aaaa = try #require(GatewayDNS.parseQuery(aaaaQuery))
        #expect(aaaa.type == GatewayDNS.typeAAAA)
        let aaaaNodata = GatewayDNS.answer(
            id: aaaa.id,
            name: aaaa.name,
            address: nil,
            type: aaaa.type
        )
        #expect(aaaaNodata[3] & 0x0f == 0)
        #expect(Array(aaaaNodata.suffix(4)) == [0, 28, 0, 1])
    }

    @Test func dnsUpstreamsHonorContainerServers() async {
        #expect(GatewayDNS.upstreams(for: []) == GatewayDNS.upstream)
        #expect(!GatewayDNS.upstream.isEmpty)
        #expect(GatewayDNS.upstreams(for: ["", "  "]) == GatewayDNS.upstream)
        #expect(GatewayDNS.upstreams(for: [" 8.8.4.4 ", "1.0.0.1"]) == ["8.8.4.4", "1.0.0.1"])
        for server in GatewayDNS.systemServers() {
            #expect(server.contains("."))
            #expect(!server.contains(":"))
        }

        let gw = NetworkGateway()
        await gw.setDNS(containerID: "c1", nameservers: ["8.8.4.4"])
        #expect(await gw.dnsUpstreams(for: "c1") == ["8.8.4.4"])
        await gw.setDNS(containerID: "c2", nameservers: [])
        #expect(await gw.dnsUpstreams(for: "c2") == GatewayDNS.upstream)
        await gw.detach(containerID: "c1")
        #expect(await gw.dnsUpstreams(for: "c1") == GatewayDNS.upstream)
    }

    @Test func ipv4EncodePacksLargePayloadLength() {
        let src = IPv4Address(0xAC11_0002)
        let dst = IPv4Address(0xC0A8_FF01)
        let packet = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoUDP, src: src, dst: dst, payload: Data(count: 300))
        let encoded = packet.encode()
        #expect(encoded.count == 320)
        #expect(encoded[2] == 0x01)
        #expect(encoded[3] == 0x40)
    }

    @Test func ipv4PeekReadsTupleWithoutReencoding() throws {
        let src = IPv4Address(0xAC11_0002)
        let dst = IPv4Address(0x0101_0101)
        let tcp = Data([
            0x9c, 0x40, 0x01, 0xbb, 0, 0, 0, 1, 0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0
        ])
        let packet = IPv4Packet(tos: 0, id: 1, ttl: 64, proto: Ethernet.protoTCP, src: src, dst: dst, payload: tcp)
        let encoded = packet.encode()
        let frame = Ethernet.frame(
            dst: MACAddress(0x0A00_2700_0001),
            src: MACAddress(0x0A00_2700_0002),
            type: Ethernet.typeIPv4,
            payload: encoded
        )
        #expect(IPv4Peek.ethernetType(frame) == Ethernet.typeIPv4)
        let datagram = try #require(IPv4Peek.ipv4Datagram(fromEthernet: frame))
        let header = try #require(IPv4Peek.tuple(datagram))
        #expect(header.src == 0xAC11_0002)
        #expect(header.dst == 0x0101_0101)
        #expect(header.proto == Ethernet.protoTCP)
        #expect(header.srcPort == 40_000)
        #expect(header.dstPort == 443)
        #expect(header.tcpFlags & TCPSegment.Flags.syn.rawValue != 0)
    }

    @Test func ethernetRoundTripAndChecksum() throws {
        let src = try MACAddress([0x0A, 0x00, 0x27, 0x00, 0x00, 0x02])
        let dst = NetworkGateway.gatewayMAC
        let payload = Data([1, 2, 3, 4])
        let frame = Ethernet.frame(dst: dst, src: src, type: Ethernet.typeIPv4, payload: payload)
        let parsed = try #require(Ethernet.parse(frame))
        #expect(parsed.src == src)
        #expect(parsed.dst == dst)
        #expect(parsed.type == Ethernet.typeIPv4)
        #expect(parsed.payload == payload)
        #expect(Ethernet.checksum(Data([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7])) == 0x220d)
    }

    @Test func tcpSegmentParsesHeaderFlagsAndPayload() throws {
        var header = Data(count: 20)
        header[0] = 0x1f // src 8080
        header[1] = 0x90
        header[2] = 0x00 // dst 80
        header[3] = 0x50
        header[4] = 0x00 // seq 0x0000_0102
        header[5] = 0x00
        header[6] = 0x01
        header[7] = 0x02
        header[12] = 0x60 // data offset 6 words: 4 bytes of options
        header[13] = TCPSegment.Flags.pushAck.rawValue
        let segment = try #require(TCPSegment.parse(header + Data([9, 9, 9, 9]) + Data([1, 2, 3])))
        #expect(segment.srcPort == 8080)
        #expect(segment.dstPort == 80)
        #expect(segment.seq == 0x0000_0102)
        #expect(segment.flags.contains(.ack))
        #expect(segment.flags.contains(.push))
        #expect(!segment.flags.contains(.syn))
        #expect(segment.payload == Data([1, 2, 3]))
        #expect(TCPSegment.parse(Data(count: 19)) == nil)
        #expect(try #require(TCPSegment.parse(header)).payload.isEmpty)
    }

    @Test func attachmentFactoryStubsFutureDrivers() throws {
        _ = try NetworkAttachmentFactory.make(driver: "bridge")
        _ = try NetworkAttachmentFactory.make(driver: "host")
        _ = try NetworkAttachmentFactory.make(driver: "none")
        #expect(throws: EngineError.self) {
            _ = try NetworkAttachmentFactory.make(driver: "macvlan")
        }
        #expect(throws: EngineError.self) {
            _ = try NetworkAttachmentFactory.make(driver: "ipvlan")
        }
        #expect(throws: EngineError.self) {
            _ = try NetworkAttachmentFactory.make(driver: "container:abc")
        }
    }

    @Test func portPublishTargetUsesLocalhostRelayWithoutHostRoute() async throws {
        let gateway = NetworkGateway()
        #expect(await gateway.utunReady == false)
        let guest = IPv4Address(0xAC11_0002)
        let target = try await gateway.portPublishTarget(guestIP: guest, guestPort: 80, udp: false)
        #expect(target.ip == "127.0.0.1")
        #expect(target.port > 0)
        await gateway.stopPortRelay(guestIP: guest, guestPort: 80, udp: false)
        await gateway.shutdown()
    }
}
