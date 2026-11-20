import Foundation
import Testing
@testable import CliCore

struct BuildCLITests {
    @Test func encodedQueryMapsFlags() throws {
        let build = try Build.parse([
            "-t", "demo:latest",
            "-t", "demo:v1",
            "--build-arg", "FOO=bar",
            "--label", "env=test",
            "--network", "bridge",
            "--add-host", "db:10.0.0.2",
            "-m", "128m",
            "--no-cache",
            "--target", "release",
            ".",
        ])
        let items = queryItems(try build.encodedQuery(dockerfile: "Dockerfile"))
        #expect(items["dockerfile"] == ["Dockerfile"])
        #expect(items["version"] == ["1"])
        #expect(items["rm"] == ["1"])
        #expect(items["t"] == ["demo:latest", "demo:v1"])
        #expect(items["networkmode"] == ["bridge"])
        #expect(items["extrahosts"] == ["db:10.0.0.2"])
        #expect(items["memory"] == ["134217728"])
        #expect(items["nocache"] == ["1"])
        #expect(items["target"] == ["release"])
        let args = try jsonObject(Data((items["buildargs"]?.first ?? "").utf8))
        #expect(args["FOO"] as? String == "bar")
        let labels = try jsonObject(Data((items["labels"]?.first ?? "").utf8))
        #expect(labels["env"] as? String == "test")
    }

    @Test func k3sSyncRequiresAnExplicitTag() throws {
        #expect(try !Build.parse([]).syncK3s)
        #expect(throws: (any Error).self) {
            var build = try Build.parse(["--k3s"])
            try build.validate()
        }
        var build = try Build.parse(["--k3s", "-t", "demo:dev"])
        try build.validate()
        #expect(build.syncK3s)
    }

    @Test func encodedQueryRejectsUnsupportedNetwork() throws {
        expectCLIError("network mode container:abc is not implemented") {
            _ = try Build.parse(["--network", "container:abc", "."]).encodedQuery(dockerfile: "Dockerfile")
        }
        expectCLIError("network mode macvlan is not implemented") {
            _ = try Build.parse(["--network", "macvlan", "."]).encodedQuery(dockerfile: "Dockerfile")
        }
    }

    @Test func contextRelativeDockerfileRejectsEscape() throws {
        expectCLIError("Forbidden path outside the build context") {
            _ = try Build.contextRelativeDockerfile(
                "../Dockerfile",
                context: URL(fileURLWithPath: "/tmp/ctx", isDirectory: true)
            )
        }
    }
}
