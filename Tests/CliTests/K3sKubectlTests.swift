import Foundation
import Testing
@testable import CliCore

struct K3sKubectlTests {
    @Test(arguments: ["v1.33.9", "v1.34.3", "v1.35.1+k3s1"])
    func supportsClientMinorVersionSkew(_ version: String) {
        #expect(K3s.Kubectl.isCompatible(version))
    }

    @Test(arguments: ["v1.32.9", "v1.36.0", "v2.34.0", "not kubectl"])
    func rejectsUnsupportedClients(_ version: String) {
        #expect(!K3s.Kubectl.isCompatible(version))
    }

    @Test func prefersCompatiblePathClientAndFallsBackToBundled() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let system = root.appendingPathComponent("kubectl")
        let bundled = root.appendingPathComponent("bundled")
        func install(_ version: String, at url: URL) throws {
            let output = #"{"clientVersion":{"gitVersion":"VERSION"}}"#.replacingOccurrences(of: "VERSION", with: version)
            try "#!/bin/sh\nprintf '%s\\n' '\(output)'\n".write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try install("v1.34.3", at: bundled)
        try install("v1.35.1", at: system)
        #expect(try K3s.Kubectl.selectClient(path: root.path, bundled: bundled).path == system.path)
        try install("v1.36.0", at: system)
        #expect(try K3s.Kubectl.selectClient(path: root.path, bundled: bundled).path == bundled.path)
        try fm.removeItem(at: system)
        #expect(try K3s.Kubectl.selectClient(path: root.path, bundled: bundled).path == bundled.path)
    }

    @Test func preservesRemoteArgumentsAndRejectsClusterOverrides() throws {
        let arguments = ["exec", "web", "--", "/bin/cmd", "-h", "--server=other"]
        for command in [["kubectl"], ["k3s", "kubectl"]] {
            let invocation = ["macker"] + command + arguments
            let parsed = DockerGlobalFlags.install(from: invocation)
            #expect(parsed == invocation)
            let kubectl = try #require(Macker.parseAsRoot(Array(parsed.dropFirst())) as? K3s.Kubectl)
            #expect(kubectl.arguments == arguments)
        }
        try K3s.Kubectl.validateTarget(arguments)
        #expect(throws: (any Error).self) { try K3s.Kubectl.validateTarget(["get", "nodes", "--context=other"]) }
        #expect(throws: (any Error).self) { try K3s.Kubectl.validateTarget(["-shttp://localhost", "get", "nodes"]) }
    }
}
