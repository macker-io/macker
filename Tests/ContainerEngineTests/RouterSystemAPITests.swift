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
