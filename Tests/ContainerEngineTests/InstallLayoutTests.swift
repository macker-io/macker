import Foundation
import Testing
@testable import ContainerEngine

struct InstallLayoutTests {
    @Test func binLayoutFindsPrefixShare() {
        let exe = URL(fileURLWithPath: "/opt/homebrew/bin/mackerd")
        let roots = InstallLayout.shareRoots(executableDirectory: exe.deletingLastPathComponent())
        #expect(roots.map(\.path) == ["/opt/homebrew/share/macker"])
        let runtime = InstallLayout.runtimeDirectories(executable: exe)
        #expect(runtime.map(\.path).contains("/opt/homebrew/share/macker/runtime"))
        #expect(InstallLayout.versionFileCandidates(executable: exe).map(\.path) == [
            "/opt/homebrew/share/macker/VERSION",
        ])
    }

    @Test func libexecLayoutFindsPrefixShare() {
        let exeDir = URL(fileURLWithPath: "/opt/homebrew/libexec/macker", isDirectory: true)
        let roots = InstallLayout.shareRoots(executableDirectory: exeDir)
        #expect(roots.map(\.path).contains("/opt/homebrew/share/macker"))
        let exe = exeDir.appendingPathComponent("mackerd")
        #expect(InstallLayout.runtimeDirectories(executable: exe).map(\.path)
            .contains("/opt/homebrew/share/macker/runtime"))
        #expect(InstallLayout.versionFileCandidates(executable: exe).map(\.path)
            .contains("/opt/homebrew/share/macker/VERSION"))
    }

    @Test func appMacOSLooksInResources() {
        let exe = URL(fileURLWithPath: "/Applications/Macker.app/Contents/MacOS/mackerd")
        let dirs = InstallLayout.runtimeDirectories(executable: exe)
        #expect(dirs.map(\.path).contains("/Applications/Macker.app/Contents/Resources/runtime"))
        #expect(dirs.map(\.path).contains("/Applications/Macker.app/Contents/MacOS/runtime"))
    }
}
