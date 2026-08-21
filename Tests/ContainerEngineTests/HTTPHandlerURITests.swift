import Testing
@testable import DockerAPIAdapter

struct HTTPHandlerURITests {
    @Test func parseURISplitsPathAndRepeatedQueryKeys() {
        let parsed = HTTPHandler.parseURI("/v1.41/build?t=demo:latest&t=demo:v1&nocache=1")
        #expect(parsed.path == "/v1.41/build")
        #expect(parsed.query["t"] == "demo:v1")
        #expect(parsed.query["nocache"] == "1")
        #expect(parsed.queryAll["t"] == ["demo:latest", "demo:v1"])
    }

    @Test func parseURIDecodesPercentEncoding() {
        let parsed = HTTPHandler.parseURI("/containers/json?filters=%7B%22name%22%3A%5B%22web%22%5D%7D")
        #expect(parsed.path == "/containers/json")
        #expect(parsed.query["filters"] == "{\"name\":[\"web\"]}")
    }

    @Test func parseURIWithoutQueryKeepsPath() {
        let parsed = HTTPHandler.parseURI("/_ping")
        #expect(parsed.path == "/_ping")
        #expect(parsed.query.isEmpty)
        #expect(parsed.queryAll.isEmpty)
    }
}
