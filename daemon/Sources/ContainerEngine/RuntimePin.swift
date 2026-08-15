import Foundation

/// Guest-runtime pins used only by the daemon MicroVM path.
///
/// Edit `RuntimePin.json` when bumping the bundled containerization / Kata
/// artifacts. `vminit` and the Kata archive URL are derived unless the JSON
/// supplies an override.
public struct RuntimePin: Sendable, Codable, Equatable {
    public let containerization: String
    public let kata: String
    public let vminitReferenceOverride: String?
    public let kataArchiveURLOverride: String?

    enum CodingKeys: String, CodingKey {
        case containerization
        case kata
        case vminitReferenceOverride = "vminitReference"
        case kataArchiveURLOverride = "kataArchiveURL"
    }

    public var vminitReference: String {
        if let vminitReferenceOverride, !vminitReferenceOverride.isEmpty {
            return vminitReferenceOverride
        }
        return "ghcr.io/apple/containerization/vminit:\(containerization)"
    }

    public var kataArchiveURL: URL {
        if let kataArchiveURLOverride, let url = URL(string: kataArchiveURLOverride) {
            return url
        }
        return URL(
            string:
                "https://github.com/kata-containers/kata-containers/releases/download/\(kata)/kata-static-\(kata)-arm64.tar.xz"
        )!
    }

    public static let current: RuntimePin = load()

    public static func load(from url: URL) throws -> RuntimePin {
        try JSONDecoder().decode(RuntimePin.self, from: Data(contentsOf: url))
    }

    /// Runtime folders inside a packaged `.app` or next to the executable.
    public static func bundledRuntimeDirectories() -> [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("runtime", isDirectory: true))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()
        dirs.append(exeDir.appendingPathComponent("runtime", isDirectory: true))
        if exeDir.lastPathComponent == "MacOS" {
            dirs.append(
                exeDir.deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("runtime", isDirectory: true)
            )
        }
        return dirs
    }

    /// Checkout-only packaging cache (`daemon/.runtime`). Not the runtime store.
    public static var checkoutRuntimeDirectory: URL {
        daemonRoot.appendingPathComponent(".runtime", isDirectory: true)
    }

    static var daemonRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static var jsonURL: URL? {
        if let bundled = Bundle.module.url(forResource: "RuntimePin", withExtension: "json") {
            return bundled
        }
        for directory in bundledRuntimeDirectories() + [checkoutRuntimeDirectory] {
            let candidate = directory.appendingPathComponent("RuntimePin.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let nextToSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("RuntimePin.json")
        if FileManager.default.fileExists(atPath: nextToSource.path) {
            return nextToSource
        }
        return nil
    }

    private static func load() -> RuntimePin {
        guard let url = jsonURL else {
            fatalError("RuntimePin.json is missing from the ContainerEngine resources")
        }
        do {
            return try load(from: url)
        } catch {
            fatalError("RuntimePin.json is invalid: \(error.localizedDescription)")
        }
    }
}
