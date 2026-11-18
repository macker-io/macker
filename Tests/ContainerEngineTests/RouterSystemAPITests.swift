import Foundation
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

struct RouterSystemAPITests {
    @Test func infoAndDiskUsage() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            _ = try await RouterTestSupport.createContainer(router, name: "web")
            _ = await router.handle(
                try RouterTestSupport.request("POST", "/volumes/create", body: ["Name": "data"])
            )

            let info = await router.handle(try RouterTestSupport.request("GET", "/info"))
            #expect(info.status == 200)
            let body = try RouterTestSupport.jsonObject(info)
            #expect(body["BuilderVersion"] as? String == "2")
            // Runtime platform (the Linux guest), not the Mac host.
            #expect(body["OSType"] as? String == "linux")
            #expect(body["Architecture"] as? String == "aarch64")
            #expect((body["Images"] as? NSNumber)?.intValue ?? 0 >= 1)
            #expect((body["Containers"] as? NSNumber)?.intValue ?? 0 >= 1)

            let df = await router.handle(try RouterTestSupport.request("GET", "/system/df"))
            #expect(df.status == 200)
            let usage = try RouterTestSupport.jsonObject(df)
            #expect(((usage["Images"] as? [Any])?.isEmpty) == false)
            #expect(((usage["Containers"] as? [Any])?.isEmpty) == false)
            #expect(((usage["Volumes"] as? [Any])?.isEmpty) == false)
        }
    }

    @Test func mackerStatusReportsIdleAndClearsAfterBuildFailure() async throws {
        try await withRouter { router, _ in
            let statusRequest = try RouterTestSupport.request("GET", "/macker/status")
            let idle = await router.handle(statusRequest)
            #expect(idle.status == 200)
            #expect(try RouterTestSupport.jsonObject(idle)["runningContainers"] as? Int == 0)
            #expect(try RouterTestSupport.jsonObject(idle)["activeBuilds"] as? Int == 0)

            try await TemporaryDirectory.with("macker-build-status") { work in
                let archive = try pack(hello: "invalid Dockerfile", in: work, file: "Dockerfile")
                let response = await router.handle(try RouterTestSupport.request("POST", "/build", bodyFile: archive))
                guard case .stream(let body) = response.body else {
                    Issue.record("expected build progress stream")
                    return
                }
                var output = ""
                for await var chunk in body.chunks {
                    output += chunk.readString(length: chunk.readableBytes) ?? ""
                }
                #expect(output.contains("\"error\""))
            }

            let after = await router.handle(statusRequest)
            #expect(try RouterTestSupport.jsonObject(after)["activeBuilds"] as? Int == 0)
        }
    }

    @Test func authRequiresBody() async throws {
        try await withRouter { router, _ in
            let empty = await router.handle(try RouterTestSupport.request("POST", "/auth"))
            #expect(empty.status == 400)
            #expect(
                try RouterTestSupport.jsonObject(empty)["message"] as? String == "username and password required"
            )
        }
    }
}
