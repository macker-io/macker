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

    @Test func rejectsIPv6AndMultipleSubnets() throws {
        expectCLIError("IPv6 subnet is not supported") {
            _ = try NetworkCreate.parse(["--subnet", "fe80::/64", "n1"]).encodedBody()
        }
        expectCLIError("only one IPv4 subnet is supported") {
            _ = try NetworkCreate.parse(["--subnet", "172.20.0.0/16", "--subnet", "172.21.0.0/16", "n1"]).encodedBody()
        }
    }
}
