import Foundation
import Testing
@testable import HelperSupport

struct HelperProtocolTests {
    @Test func utunNames() {
        #expect(HelperNetText.isUtunInterface("utun0"))
        #expect(HelperNetText.isUtunInterface("utun12"))
        #expect(!HelperNetText.isUtunInterface("utun"))
        #expect(!HelperNetText.isUtunInterface("utun-1"))
        #expect(!HelperNetText.isUtunInterface("utun0;id"))
        #expect(!HelperNetText.isUtunInterface("en0"))
        #expect(!HelperNetText.isUtunInterface("/tmp/utun0"))
    }

    @Test func ipv4AndCIDR() {
        #expect(HelperNetText.isIPv4("192.168.255.1"))
        #expect(HelperNetText.isIPv4CIDR("172.17.0.0/16"))
        #expect(HelperNetText.isIPv4CIDR("192.168.255.0/24"))
        #expect(!HelperNetText.isIPv4("192.168.255.1/32"))
        #expect(!HelperNetText.isIPv4CIDR("172.17.0.0/16;rm"))
        #expect(!HelperNetText.isIPv4CIDR("172.17.0.0"))
        #expect(!HelperNetText.isIPv4CIDR("not-an-ip/24"))
        #expect(HelperNetText.netmask(prefix: 32) == "255.255.255.255")
        #expect(HelperNetText.netmask(prefix: 24) == "255.255.255.0")
        #expect(HelperNetText.netmask(prefix: 16) == "255.255.0.0")
    }

    @Test func attachRejectsInjection() throws {
        #expect(throws: HelperError.self) {
            try HelperRequest.attach(
                address: "192.168.255.1",
                peer: "192.168.255.1",
                prefix: 32,
                routes: ["172.17.0.0/16;id"]
            ).validated()
        }
        #expect(throws: HelperError.self) {
            try HelperRequest.addRoute(interface: "utun0;rm", subnet: "172.17.0.0/16").validated()
        }
        let attached = try HelperRequest.attach(
            address: "192.168.255.1",
            peer: "192.168.255.1",
            prefix: 32,
            routes: ["172.17.0.0/16"]
        ).validated()
        #expect(
            attached == .attach(
                address: "192.168.255.1",
                peer: "192.168.255.1",
                prefix: 32,
                routes: ["172.17.0.0/16"]
            )
        )
        #expect(throws: HelperError.self) {
            try HelperRequest.teardown(interface: "en0").validated()
        }
    }

    @Test func launchDaemonPlistPinsServe() {
        let plist = HelperInstaller.launchDaemonPlist()
        #expect(plist.contains("<string>\(HelperPaths.label)</string>"))
        #expect(plist.contains("<string>\(HelperPaths.installedBinaryPath)</string>"))
        #expect(plist.contains("<string>serve</string>"))
        #expect(!plist.contains("ifconfig"))
    }

    @Test func locateBinaryPrefersSibling() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("macker")
        let helper = dir.appendingPathComponent("macker-helper")
        try Data().write(to: cli)
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        #expect(HelperInstaller.locateBinary(argv0: cli.path) == helper)
    }

    @Test func requestRoundTrip() throws {
        let request = HelperRequest.attach(
            address: "192.168.255.1",
            peer: "192.168.255.1",
            prefix: 32,
            routes: ["172.17.0.0/16"]
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
        #expect(decoded.op == .attach)
        let add = try JSONEncoder().encode(HelperRequest.addRoute(interface: "utun0", subnet: "10.0.0.0/24"))
        #expect(String(data: add, encoding: .utf8)?.contains("add-route") == true)
    }
}
