import Testing
@testable import DockerAPIAdapter

struct ExecRouteTests {
    @Test func matchKill() {
        #expect(Router.matchNamedExec(method: "POST", path: "/exec/abc123/kill") == .kill("abc123"))
        #expect(Router.matchNamedExec(method: "GET", path: "/exec/abc123/kill") == nil)
    }

    @Test func matchExistingExecRoutes() {
        #expect(Router.matchNamedExec(method: "POST", path: "/exec/abc123/start") == .start("abc123"))
        #expect(Router.matchNamedExec(method: "GET", path: "/exec/abc123/json") == .inspect("abc123"))
        #expect(Router.matchNamedExec(method: "POST", path: "/exec/abc123/resize") == .resize("abc123"))
    }

    @Test func querySignalDefaultsToKill() {
        #expect(Router.querySignal(nil) == "SIGKILL")
        #expect(Router.querySignal("") == "SIGKILL")
        #expect(Router.querySignal("SIGINT") == "SIGINT")
    }
}
