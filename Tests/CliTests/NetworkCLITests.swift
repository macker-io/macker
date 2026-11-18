import Foundation
import Testing
@testable import CliCore

struct NetworkCLITests {
    @Test func encodedBodyMapsCreateFlags() throws {
        let command = try NetworkCreate.parse([
            "--label", "env=test",
            "--subnet", "172.20.0.0/16",
            "--gateway", "172.20.0.1",
            "--internal",
            "front",
        ])
        let body = try jsonObject(try command.encodedBody())
        #expect(body["Name"] as? String == "front")
        #expect(body["Driver"] as? String == "bridge")
        #expect(body["Internal"] as? Bool == true)
        #expect(body["EnableIPv6"] as? Bool == false)
        let labels = body["Labels"] as? [String: String]
        #expect(labels?["env"] == "test")
        let ipam = try jsonObject(body["IPAM"])
        let config = ipam["Config"] as? [[String: String]]
        #expect(config?.first?["Subnet"] == "172.20.0.0/16")
        #expect(config?.first?["Gateway"] == "172.20.0.1")
    }

    @Test func encodesIPv6AndRejectsMultipleSubnets() throws {
        let command = try NetworkCreate.parse([
            "--ipv6", "true",
            "--subnet", "172.20.0.0/16",
            "--subnet", "fd00:20::/64",
            "--gateway", "fd00:20::1",
            "n1",
        ])
        let body = try jsonObject(try command.encodedBody())
        #expect(body["EnableIPv6"] as? Bool == true)
        let ipam = try jsonObject(body["IPAM"])
        let config = ipam["Config"] as? [[String: String]]
        #expect(config?.count == 2)
        #expect(config?[1]["Subnet"] == "fd00:20::/64")
        #expect(config?[1]["Gateway"] == "fd00:20::1")

        expectCLIError("only one IPv4 subnet is supported") {
            _ = try NetworkCreate.parse(["--subnet", "172.20.0.0/16", "--subnet", "172.21.0.0/16", "n1"]).encodedBody()
        }
    }
}
