import Foundation
import Testing
@testable import DockerAPIAdapter

/// The BuildKit `Control` edits behind `docker build` with buildx's `docker` driver.
struct BuildKitWireTests {
    private func exporter(_ type: String, attrs: [(String, String)]) -> ProtoWire.Field {
        var fields = [ProtoWire.string(type, field: 1)]
        for (key, value) in attrs {
            fields.append(ProtoWire.mapEntry(key, value, field: 2))
        }
        return ProtoWire.Field(number: 13, value: .bytes(ProtoWire.encode(fields)))
    }

    @Test func mobyExporterBecomesImageAndKeepsEverythingElse() throws {
        let request = ProtoWire.encode([
            ProtoWire.string("ref-1", field: 1),
            ProtoWire.string("session-1", field: 5),
            ProtoWire.mapEntry("build-arg:A", "1", field: 7),
            exporter("moby", attrs: [("name", "docker.io/compat/a:1,docker.io/compat/a:latest"), ("prefer-image-digest", "true")]),
            ProtoWire.Field(number: 11, value: .varint(1)),
        ])
        let (rewritten, export) = try BuildKitControl.rewriteSolveRequest(request)
        #expect(export?.names == ["docker.io/compat/a:1", "docker.io/compat/a:latest"])
        let fields = try ProtoWire.decode(rewritten)
        #expect(fields.map(\.number) == [1, 5, 7, 13, 11])
        guard case .bytes(let raw) = fields[3].value else {
            Issue.record("exporter not bytes")
            return
        }
        let exporterFields = try ProtoWire.decode(raw)
        #expect(exporterFields.first == ProtoWire.string("image", field: 1))
        #expect(exporterFields.count == 3)
    }

    @Test func otherExportersPassThroughByteForByte() throws {
        let request = ProtoWire.encode([exporter("oci", attrs: [("dest", "/tmp/x")]), ProtoWire.string("s", field: 5)])
        let (rewritten, export) = try BuildKitControl.rewriteSolveRequest(request)
        #expect(export == nil)
        #expect(rewritten == request)
    }

    @Test func deprecatedSingleExporterIsRewrittenToo() throws {
        let request = ProtoWire.encode([
            ProtoWire.string("moby", field: 3),
            ProtoWire.mapEntry("name", "x:1", field: 4),
        ])
        let (rewritten, export) = try BuildKitControl.rewriteSolveRequest(request)
        #expect(export?.names == ["x:1"])
        #expect(try ProtoWire.decode(rewritten).first == ProtoWire.string("image", field: 3))
    }

    @Test func solveResponseMapIsReadAndEdited() throws {
        let response = ProtoWire.encode([
            ProtoWire.mapEntry("containerimage.digest", "sha256:aaa", field: 1),
            ProtoWire.mapEntry("image.name", "x:1", field: 1),
        ])
        #expect(try BuildKitControl.exporterResponse(response) == ["containerimage.digest": "sha256:aaa", "image.name": "x:1"])
        let edited = try BuildKitControl.rewriteExporterResponse(response, set: ["containerimage.digest": "sha256:bbb"])
        #expect(try BuildKitControl.exporterResponse(edited) == ["containerimage.digest": "sha256:bbb", "image.name": "x:1"])
    }

    @Test func grpcFramesSplitAcrossReadsAndCarrySessionBytes() throws {
        let one = GRPCFraming.frame(BuildKitControl.bytesMessage(Data("hello".utf8)))
        let two = GRPCFraming.frame(BuildKitControl.bytesMessage(Data(repeating: 7, count: 300)))
        var buffer = one + two.prefix(4)
        var messages = GRPCFraming.takeMessages(&buffer)
        #expect(messages.count == 1)
        #expect(try BuildKitControl.bytesMessageData(messages[0].payload) == Data("hello".utf8))
        buffer.append(two.dropFirst(4))
        messages = GRPCFraming.takeMessages(&buffer)
        #expect(messages.count == 1)
        #expect(try BuildKitControl.bytesMessageData(messages[0].payload) == Data(repeating: 7, count: 300))
        #expect(buffer.isEmpty)
    }

    @Test func varintsAndUnknownWireTypesRoundTrip() throws {
        let fields = [
            ProtoWire.Field(number: 2, value: .varint(300)),
            ProtoWire.Field(number: 3, value: .fixed64(Data(repeating: 1, count: 8))),
            ProtoWire.Field(number: 4, value: .fixed32(Data(repeating: 2, count: 4))),
            ProtoWire.Field(number: 1000, value: .bytes(Data([1, 2, 3]))),
        ]
        #expect(try ProtoWire.decode(ProtoWire.encode(fields)) == fields)
        #expect(throws: ProtoWire.DecodeError.self) { try ProtoWire.decode(Data([0x0a, 0x05, 0x01])) }
    }
}
