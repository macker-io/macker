import Foundation

/// Turns a host directory into the tar the daemon receives on `POST /build`.
/// Lives here rather than in the CLI so `.dockerignore` handling is testable.
public enum BuildContext {
    public static let defaultDockerfile = "Dockerfile"

    public static func loadIgnore(root: URL) -> DockerIgnore {
        let file = root.appendingPathComponent(".dockerignore")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return DockerIgnore("")
        }
        return DockerIgnore(text)
    }

    /// Relative paths to archive: files, symlinks, and the directories that hold them.
    /// `alwaysInclude` survives `.dockerignore`, which is how Docker keeps the Dockerfile.
    public static func entries(root: URL, ignore: DockerIgnore, alwaysInclude: [String] = []) throws -> [String] {
        let fm = FileManager.default
        let kept = Set(alwaysInclude.map(Self.normalize))
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw EngineError.invalidArgument("cannot read build context at \(root.path)")
        }

        var files: [String] = []
        var directories: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            guard let relative = FSInventory.containerPath(for: url, root: root).map({ String($0.dropFirst()) }) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values?.isSymbolicLink != true && values?.isDirectory == true
            let excluded = !kept.contains(relative) && ignore.excludes(relative)
            if isDirectory {
                if excluded, !ignore.hasNegations {
                    enumerator.skipDescendants()
                }
                if !excluded {
                    directories.insert(relative)
                }
                continue
            }
            if excluded { continue }
            files.append(relative)
            for parent in DockerIgnore.selfAndParents(relative).dropFirst() {
                directories.insert(parent)
            }
        }
        return (directories.sorted() + files.sorted())
    }

    /// Packs `root` into `archive`, keeping `dockerfile` even when `.dockerignore` lists it.
    @discardableResult
    public static func pack(root: URL, dockerfile: String = defaultDockerfile, into archive: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.invalidArgument("unable to prepare context: path \(root.path) not found")
        }
        let relative = normalize(dockerfile)
        guard !relative.hasPrefix("../"), relative != ".." else {
            throw EngineError.invalidArgument("Forbidden path outside the build context: \(dockerfile)")
        }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) else {
            throw EngineError.invalidArgument("Cannot locate specified Dockerfile: \(relative)")
        }
        let paths = try entries(root: root, ignore: loadIgnore(root: root), alwaysInclude: [relative, ".dockerignore"])
        guard !paths.isEmpty else {
            throw EngineError.invalidArgument("build context is empty")
        }
        try TarArchive.create(contentsOf: root, paths: paths, into: archive)
        return paths.count
    }

    /// Reads the Dockerfile out of an extracted context, rejecting paths that escape it.
    public static func dockerfile(in root: URL, named dockerfile: String) throws -> String {
        let relative = normalize(dockerfile)
        guard !relative.hasPrefix("../"), relative != ".." else {
            throw EngineError.invalidArgument("Forbidden path outside the build context: \(dockerfile)")
        }
        let url = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw EngineError.invalidArgument("Cannot locate specified Dockerfile: \(relative)")
        }
        return text
    }

    static func normalize(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("./") { value = String(value.dropFirst(2)) }
        while value.hasPrefix("/") { value = String(value.dropFirst()) }
        return value
    }
}
