import CryptoKit
import Foundation

/// Maps a build step to the intermediate image it produced. Intermediate images are
/// stored untagged (reference == digest), so they show up as dangling and can be pruned.
/// Persisted next to the content store as `build-cache.json`.
struct BuildCache: Sendable {
    private let url: URL
    private var entries: [String: String]

    init(store: URL) {
        url = store.appendingPathComponent("build-cache.json")
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    var references: [String] { Array(Set(entries.values)).sorted() }

    func reference(for key: String) -> String? { entries[key] }

    mutating func record(key: String, reference: String) {
        entries[key] = reference
        save()
    }

    mutating func forget(references dropped: Set<String>) {
        entries = entries.filter { !dropped.contains($0.value) }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Cache key for one step: the parent image plus the instruction, and for
    /// `COPY` / `ADD` a digest of the files being added.
    static func key(parent: String, instruction: String, inputs: [String] = []) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(parent.utf8))
        hasher.update(data: Data("\n".utf8))
        hasher.update(data: Data(instruction.utf8))
        for input in inputs {
            hasher.update(data: Data("\n".utf8))
            hasher.update(data: Data(input.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stable fingerprint of a staged tree: relative path, kind, permissions, size and
    /// file contents. Used so `COPY` re-runs when the context changes.
    static func fingerprint(of root: URL) throws -> String {
        var lines: [String] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return "empty"
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            urls.append(url)
        }
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard let relative = FSInventory.containerPath(for: url, root: root) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let mode = ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            if values?.isSymbolicLink == true {
                let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                lines.append("l \(relative) \(target)")
                continue
            }
            if values?.isDirectory == true {
                lines.append("d \(relative) \(mode)")
                continue
            }
            let digest = (try? TarArchive.sha256(of: url)) ?? "unreadable"
            lines.append("f \(relative) \(mode) \(values?.fileSize ?? 0) \(digest)")
        }
        var hasher = SHA256()
        hasher.update(data: Data(lines.joined(separator: "\n").utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
