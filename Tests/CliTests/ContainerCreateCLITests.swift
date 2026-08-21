import Foundation
import Testing
@testable import CliCore

struct ContainerCreateCLITests {
    @Test func encodeRequestMapsFlagsToCreateBody() throws {
        let options = try ContainerCreateOptions.parse([
            "--name", "web",
            "-p", "8080:80",
            "--cpus", "1.5",
            "--memory", "128m",
            "--restart", "always",
            "--health-cmd", "true",
            "--health-interval", "1s",
            "--health-retries", "2",
            "--add-host", "db:10.0.0.2",
            "--label", "env=prod",
            "alpine",
            "echo",
            "hi",
        ])
        let encoded = try Create.encodeRequest(options, autoRemove: false)
        #expect(encoded.path == "/containers/create?name=web")

        let body = try jsonObject(encoded.body)
        #expect(body["Image"] as? String == "alpine")
        #expect(body["Cmd"] as? [String] == ["echo", "hi"])
        let labels = body["Labels"] as? [String: String]
        #expect(labels?["env"] == "prod")

        let host = try jsonObject(body["HostConfig"])
        #expect(host["AutoRemove"] == nil)
        #expect(int64(host["NanoCpus"]) == Int64(1_500_000_000))
        #expect(int64(host["Memory"]) == Int64(128) * 1_048_576)
        #expect(host["ExtraHosts"] as? [String] == ["db:10.0.0.2"])
        let restart = try jsonObject(host["RestartPolicy"])
        #expect(restart["Name"] as? String == "always")
        let bindings = try jsonObject(host["PortBindings"])
        let published = bindings["80/tcp"] as? [[String: String]]
        #expect(published?.first?["HostPort"] == "8080")

        let health = try jsonObject(body["Healthcheck"])
        #expect(health["Test"] as? [String] == ["CMD-SHELL", "true"])
        #expect(int64(health["Interval"]) == Int64(1_000_000_000))
        #expect(int64(health["Retries"]) == 2)
    }

    @Test func encodeRequestSetsAutoRemoveWithoutRestart() throws {
        let encoded = try Create.encodeRequest(
            ContainerCreateOptions.parse(["alpine"]),
            autoRemove: true
        )
        let host = try jsonObject(try jsonObject(encoded.body)["HostConfig"])
        #expect(host["AutoRemove"] as? Bool == true)
    }

    @Test func encodeRequestRejectsIPv6RestartConflictAndBadPull() throws {
        expectCLIError("IPv6 is not implemented") {
            _ = try Create.encodeRequest(
                ContainerCreateOptions.parse(["--ip6", "fe80::1", "alpine"]),
                autoRemove: false
            )
        }
        expectCLIError("Conflicting options: --restart and --rm") {
            _ = try Create.encodeRequest(
                ContainerCreateOptions.parse(["--restart", "always", "alpine"]),
                autoRemove: true
            )
        }
        expectCLIError("invalid --pull value") {
            _ = try Create.encodeRequest(
                ContainerCreateOptions.parse(["--pull", "sometimes", "alpine"]),
                autoRemove: false
            )
        }
    }

    @Test func encodeRequestMapsNetworkMountDnsEnvAndExpose() throws {
        let encoded = try Create.encodeRequest(
            ContainerCreateOptions.parse([
                "--network", "bridge",
                "--dns", "1.1.1.1",
                "--env", "FOO=bar",
                "--expose", "443",
                "-v", "/tmp/data:/data",
                "--mount", "type=bind,source=/tmp/src,target=/mnt,readonly",
                "alpine",
            ]),
            autoRemove: false
        )
        let body = try jsonObject(encoded.body)
        #expect(body["Env"] as? [String] == ["FOO=bar"])
        let exposed = try jsonObject(body["ExposedPorts"])
        #expect(exposed["443/tcp"] != nil)

        let host = try jsonObject(body["HostConfig"])
        #expect(host["NetworkMode"] as? String == "bridge")
        #expect(host["Dns"] as? [String] == ["1.1.1.1"])
        #expect(host["Binds"] as? [String] == ["/tmp/data:/data"])
        let mounts = host["Mounts"] as? [[String: Any]]
        #expect(mounts?.contains { ($0["Type"] as? String) == "bind" && ($0["Target"] as? String) == "/mnt" && ($0["ReadOnly"] as? Bool) == true } == true)

        let networks = try jsonObject(try jsonObject(body["NetworkingConfig"])["EndpointsConfig"])
        #expect(networks["bridge"] != nil)
    }

    @Test func runStreamsHonorAttachAndInteractive() {
        #expect(Run.streams(attach: [], interactive: false) == (false, true, true))
        #expect(Run.streams(attach: [], interactive: true) == (true, true, true))
        #expect(Run.streams(attach: ["stdin", "stdout"], interactive: false) == (true, true, false))
        #expect(Run.streams(attach: ["i", "e"], interactive: false) == (true, false, true))
    }
}
