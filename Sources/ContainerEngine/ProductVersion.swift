import Foundation

/// Marketing version shared by the GUI app, daemon, and CLI.
///
/// Debug is `0.0.0`. Packaged builds take `MACKER_VERSION`, the host
/// bundle's `CFBundleShortVersionString`, or `share/macker/VERSION`.
public enum ProductVersion {
    public static let current: String = load()
    public static let debugDefault = "0.0.0"

    private static func load() -> String {
        if let env = ProcessInfo.processInfo.environment["MACKER_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty
        {
            return env
        }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let version = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty {
                return version
            }
        }
        for candidate in InstallLayout.versionFileCandidates() {
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else {
                continue
            }
            let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty {
                return version
            }
        }
        return debugDefault
    }
}
