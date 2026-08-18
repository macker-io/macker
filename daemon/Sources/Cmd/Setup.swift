import ArgumentParser
import ContainerEngine
import Foundation

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Configure the shell alias and Docker-compatible socket symlink."
    )

    @Flag(name: .long, help: "Print the planned changes without writing files.")
    var dryRun = false

    @Flag(name: .long, help: "Replace an existing /var/run/docker.sock if it does not already point at Macker.")
    var force = false

    func run() throws {
        print("Macker setup")
        print("  daemon socket: \(DaemonPaths.defaultSocketPath)")
        print("  docker socket: \(DaemonPaths.dockerCompatSocketPath)")
        print("")

        try configureAlias()
        try configureSymlink()

        print("")
        print("Next: start the daemon, then run `macker doctor`.")
        print("Guest kernel/initfs: run `macker fetch-runtime` (or `make -C daemon fetch-runtime`).")
        print("Host routes (optional, for curl <container IP>): `sudo macker helper install`.")
        print("Docker clients can use \(DaemonPaths.defaultHostURL) or, after the symlink, the default Docker socket.")
    }

    private func configureAlias() throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let rcURL = rcFile(for: shell)
        let aliasLine = Self.aliasLine(for: shell)
        try FileManager.default.createDirectory(
            at: rcURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = (try? String(contentsOf: rcURL, encoding: .utf8)) ?? ""

        if existing.contains(aliasLine) {
            print("  [ok  ] alias already present in \(rcURL.path)")
            return
        }

        if dryRun {
            print("  [warn] would append \(aliasLine) to \(rcURL.path)")
            return
        }

        var next = existing
        if !next.isEmpty && !next.hasSuffix("\n") {
            next.append("\n")
        }
        next.append("\n# macker — route `docker` through the Macker CLI\n")
        next.append(aliasLine)
        next.append("\n")
        try next.write(to: rcURL, atomically: true, encoding: .utf8)
        print("  [ok  ] added \(aliasLine) to \(rcURL.path)")
        print("         reload the shell or run: source \(rcURL.path)")
    }

    private func configureSymlink() throws {
        let fm = FileManager.default
        let link = DaemonPaths.dockerCompatSocketPath
        let target = DaemonPaths.defaultSocketPath

        if let dest = try? fm.destinationOfSymbolicLink(atPath: link), dest == target {
            print("  [ok  ] \(link) already → \(target)")
            return
        }

        if fm.fileExists(atPath: link) {
            if !force {
                print("  [warn] \(link) already exists; re-run with --force to replace it")
                print("         or: sudo ln -sfn \(target) \(link)")
                return
            }
            if dryRun {
                print("  [warn] would replace \(link) with a symlink to \(target)")
                return
            }
            try fm.removeItem(atPath: link)
        } else if dryRun {
            print("  [warn] would create \(link) → \(target) (may require sudo)")
            return
        }

        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            print("  [ok  ] created \(link) → \(target)")
        } catch {
            print("  [warn] could not create \(link): \(error.localizedDescription)")
            print("         run: sudo ln -sfn \(target) \(link)")
        }
    }

    private func rcFile(for shell: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "bash":
            return home.appendingPathComponent(".bashrc")
        case "fish":
            return home.appendingPathComponent(".config/fish/config.fish")
        default:
            return home.appendingPathComponent(".zshrc")
        }
    }

    private static func aliasLine(for shell: String) -> String {
        if URL(fileURLWithPath: shell).lastPathComponent == "fish" {
            return "alias docker macker"
        }
        return #"alias docker="macker""#
    }
}
