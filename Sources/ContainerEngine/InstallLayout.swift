import Foundation

/// Relocatable CLI prefix layout (`bin/`, `libexec/macker/`, `share/macker/`).
///
/// SwiftPM resource bundles are resolved through `Bundle.main`, which follows
/// the invoked path. Packaged binaries therefore live in `libexec/macker/`
/// next to `*.bundle`; `bin/macker` and `bin/mackerd` are exec wrappers so a
/// Homebrew or `/usr/local` symlink does not hide those bundles.
enum InstallLayout: Sendable {
    /// Guest runtime folders for a packaged prefix or `.app`.
    static func runtimeDirectories(
        executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
        mainBundle: Bundle = .main
    ) -> [URL] {
        var dirs: [URL] = []
        if let resources = mainBundle.resourceURL {
            dirs.append(resources.appendingPathComponent("runtime", isDirectory: true))
        }
        let exeDir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        dirs.append(exeDir.appendingPathComponent("runtime", isDirectory: true))
        dirs.append(contentsOf: shareRoots(executableDirectory: exeDir).map {
            $0.appendingPathComponent("runtime", isDirectory: true)
        })
        if exeDir.lastPathComponent == "MacOS" {
            dirs.append(
                exeDir.deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("runtime", isDirectory: true)
            )
        }
        return dirs
    }

    static func versionFileCandidates(
        executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])
    ) -> [URL] {
        let exeDir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        return shareRoots(executableDirectory: exeDir).map {
            $0.appendingPathComponent("VERSION")
        }
    }

    /// `share/macker` for `prefix/bin/*` and `prefix/libexec/macker/*`.
    static func shareRoots(executableDirectory exeDir: URL) -> [URL] {
        var roots = [
            exeDir.deletingLastPathComponent().appendingPathComponent("share/macker", isDirectory: true),
        ]
        if exeDir.lastPathComponent == "macker",
            exeDir.deletingLastPathComponent().lastPathComponent == "libexec"
        {
            roots.append(
                exeDir.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("share/macker", isDirectory: true)
            )
        }
        return roots
    }
}
