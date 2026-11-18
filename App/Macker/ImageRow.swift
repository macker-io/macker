import Foundation

struct ImageRow: Identifiable {
    struct Reference: Identifiable {
        let id: String
        let name: String
        let tag: String

        init(_ value: String) {
            id = value
            if let separator = value.lastIndex(of: ":"), !value[separator...].contains("/") {
                name = String(value[..<separator])
                tag = String(value[value.index(after: separator)...])
            } else {
                name = value
                tag = "—"
            }
        }
    }

    let id: String
    let references: [Reference]
    let size: Int64
    let platform: String?
    let createdAt: Date?
    let containerCount: Int

    var name: String { references.first?.name ?? "Untagged Image" }
    var tag: String {
        guard let first = references.first else { return "—" }
        return references.count == 1 ? first.tag : "\(first.tag) +\(references.count - 1)"
    }
    var shortID: String { String(id.trimmingPrefix("sha256:").prefix(12)) }
    var platformText: String { platform ?? "—" }
    var created: Date { createdAt ?? .distantPast }
    var inUse: Bool { containerCount > 0 }
    var exportReferences: [String] { references.isEmpty ? [id] : references.map(\.id) }

    func matches(_ query: String) -> Bool {
        query.isEmpty || ([name, id, platformText] + references.map(\.id)).contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    var inspectorRow: ResourceRow {
        ResourceRow(id: id, name: name, secondary: "", tertiary: "", details: [
            .init(label: "Image ID", value: id),
            .init(label: "Tags", value: references.isEmpty ? "None" : references.map(\.id).joined(separator: "\n")),
            .init(label: "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)),
            .init(label: "Platform", value: platformText),
            .init(label: "Created", value: createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"),
            .init(label: "Containers", value: "\(containerCount)"),
        ])
    }
}

extension DaemonSnapshot {
    @MainActor func imageRows() -> [ImageRow] {
        let counts = Dictionary(grouping: containers.compactMap(\.ImageID), by: { $0 }).mapValues(\.count)
        return images.map { image in
            ImageRow(
                id: image.Id,
                references: (image.RepoTags ?? []).filter { !$0.isEmpty && $0 != "<none>:<none>" && !$0.contains("@") }
                    .sorted().map(ImageRow.Reference.init),
                size: image.Size, platform: image.Platform,
                createdAt: image.Created.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                containerCount: max(image.Containers ?? 0, counts[image.Id] ?? 0)
            )
        }
    }
}
