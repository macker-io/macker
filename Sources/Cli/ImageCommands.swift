import ArgumentParser
import Foundation
import MackerTransport

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pull an image from a registry.")

    @Argument(help: "Image reference, e.g. alpine or hello-world:latest.")
    var image: String

    @Option(help: "Platform, e.g. linux/arm64.")
    var platform: String?

    @Flag(name: [.customShort("a"), .long], help: "Download all tagged images in the repository.")
    var allTags = false

    @Flag(name: [.customShort("q"), .long], help: "Suppress verbose output.")
    var quiet = false

    // Accepted for Docker CLI compatibility; content trust verification is not implemented.
    @Flag(help: "Skip image verification.")
    var disableContentTrust = false

    func run() throws { try Self.submit(image, platform: platform, allTags: allTags, quiet: quiet) }

    static func submit(_ image: String, platform: String? = nil, allTags: Bool = false, quiet: Bool = false) throws {
        let (name, tag) = DaemonAPI.splitReference(image)
        var path = "/images/create?fromImage=\(DaemonAPI.query(name))"
        if allTags {
            try DaemonAPI.requireNameOnly(image)
        } else {
            path += "&tag=\(DaemonAPI.query(tag))"
        }
        if let platform, !platform.isEmpty {
            path += "&platform=\(DaemonAPI.query(platform))"
        }
        for reference in try DaemonAPI.streamProgress(path: path, quiet: quiet ? .pull : .off) {
            print(ImageReferenceDisplay.shortened(reference))
        }
    }
}

struct Push: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Push an image to a registry.")
    @Argument var image: String

    @Option(help: "Push a platform-specific manifest as a single-platform image, e.g. linux/arm64.")
    var platform: String?

    @Flag(name: [.customShort("a"), .long], help: "Push all tags of an image to the repository.")
    var allTags = false

    @Flag(name: [.customShort("q"), .long], help: "Suppress verbose output.")
    var quiet = false

    // Accepted for Docker CLI compatibility; image signing is not implemented.
    @Flag(help: "Skip image signing.")
    var disableContentTrust = false

    func run() throws {
        let (name, tag) = DaemonAPI.splitReference(image)
        var path = "/images/\(DaemonAPI.path(name))/push"
        var query: [String] = []
        if allTags {
            try DaemonAPI.requireNameOnly(image)
        } else {
            query.append("tag=\(DaemonAPI.query(tag))")
        }
        if let platform, !platform.isEmpty {
            query.append("platform=\(DaemonAPI.query(platform))")
        }
        if !query.isEmpty {
            path += "?\(query.joined(separator: "&"))"
        }
        for digest in try DaemonAPI.streamProgress(path: path, quiet: quiet ? .push : .off) {
            print(digest)
        }
    }
}

struct ImageListOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Show all images (default hides dangling images).")
    var all = false

    @Flag(name: .shortAndLong, help: "Only show image IDs.")
    var quiet = false

    @Flag(help: "Show digests.")
    var digests = false

    @Flag(help: "Don't truncate output.")
    var noTrunc = false

    @Option(name: [.customShort("f"), .long], help: "Filter output (e.g. 'dangling=false', 'reference=alpine').")
    var filter: [String] = []

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?
}

struct Images: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List images.")

    @OptionGroup var options: ImageListOptions

    func run() throws {
        try Self.list(
            all: options.all,
            quiet: options.quiet,
            digests: options.digests,
            noTrunc: options.noTrunc,
            filters: options.filter,
            format: options.format
        )
    }

    static func list(
        all: Bool = false,
        quiet: Bool = false,
        digests: Bool = false,
        noTrunc: Bool = false,
        filters: [String] = [],
        format: String? = nil
    ) throws {
        var query: [String] = []
        if all { query.append("all=1") }
        if !filters.isEmpty {
            query.append("filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(filters)))")
        }
        let path = query.isEmpty ? "/images/json" : "/images/json?\(query.joined(separator: "&"))"
        let images = try DaemonAPI.decode([ImageSummary].self, from: DaemonAPI.get(path))

        if quiet {
            var seen = Set<String>()
            for image in images where seen.insert(image.Id).inserted {
                print(noTrunc ? image.Id : Format.shortID(image.Id))
            }
            return
        }

        // One row per stored tag; untagged images get a single <none> row.
        var rows: [[(String, String)]] = []
        for image in images {
            let tags = image.RepoTags?.filter { !$0.isEmpty } ?? []
            let pairs = tags.isEmpty ? [("<none>", "<none>")] : tags.map(splitRepoTag)
            for (repo, tag) in pairs {
                let digest = image.RepoDigests?.first { $0.hasPrefix("\(repo)@") } ?? "<none>"
                rows.append([
                    ("ID", noTrunc ? image.Id : Format.shortID(image.Id)),
                    ("Repository", ImageReferenceDisplay.shortened(repo)),
                    ("Tag", tag),
                    ("Digest", ImageReferenceDisplay.shortened(digest)),
                    ("CreatedSince", Format.timeAgo(image.Created ?? 0)),
                    ("CreatedAt", Format.createdAt(image.Created ?? 0)),
                    ("Size", Format.size(image.Size)),
                    ("VirtualSize", Format.size(image.Size)),
                ])
            }
        }

        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, rows: rows)
            return
        }

        func value(_ key: String, _ row: [(String, String)]) -> String {
            row.first { $0.0 == key }?.1 ?? ""
        }
        var headers = ["REPOSITORY", "TAG"]
        if digests { headers.append("DIGEST") }
        headers += ["IMAGE ID", "SIZE"]
        Table.print(headers: headers, rows: rows.map { row in
            var cells = [value("Repository", row), value("Tag", row)]
            if digests { cells.append(value("Digest", row)) }
            return cells + [value("ID", row), value("Size", row)]
        })
    }

    private static func splitRepoTag(_ value: String) -> (String, String) {
        if let colon = value.lastIndex(of: ":"), !value[value.index(after: colon)...].contains("/") {
            return (String(value[..<colon]), String(value[value.index(after: colon)...]))
        }
        return (value, "<none>")
    }
}

struct Rmi: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rmi", abstract: "Remove one or more images.")

    @Flag(name: [.customShort("f"), .long], help: "Force removal of the image.")
    var force = false

    @Flag(help: "Do not delete untagged parent layers.")
    var noPrune = false

    @Argument var images: [String]

    func run() throws { try Self.remove(images, force: force, noPrune: noPrune) }

    static func remove(_ images: [String], force: Bool = false, noPrune: Bool = false) throws {
        var query: [String] = []
        if force { query.append("force=1") }
        if noPrune { query.append("noprune=1") }
        let suffix = query.isEmpty ? "" : "?\(query.joined(separator: "&"))"
        for image in images {
            let response = try DaemonAPI.requireOK(DaemonAPI.delete("/images/\(DaemonAPI.path(image))\(suffix)"))
            guard let items = try? JSONDecoder().decode([ImageDeleteItem].self, from: response.body) else { continue }
            for item in items {
                if let untagged = item.untagged { print("Untagged: \(untagged)") }
                if let deleted = item.deleted { print("Deleted: \(deleted)") }
            }
        }
    }
}

struct Tag: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a tag TARGET_IMAGE that refers to SOURCE_IMAGE.")
    @Argument var source: String
    @Argument var target: String

    func run() throws {
        let (repo, tag) = DaemonAPI.splitReference(target)
        try DaemonAPI.requireOK(
            DaemonAPI.post("/images/\(DaemonAPI.path(source))/tag?repo=\(DaemonAPI.query(repo))&tag=\(DaemonAPI.query(tag))")
        )
    }
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the history of an image.")

    @Flag(help: "Don't truncate output.")
    var noTrunc = false

    @Flag(
        name: [.customShort("H"), .long],
        inversion: .prefixedNo,
        help: "Print sizes and dates in human readable format (default true)."
    )
    var human = true

    @Flag(name: [.customShort("q"), .long], help: "Only show image IDs.")
    var quiet = false

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    @Option(help: "Show history for a specific platform, e.g. linux/arm64.")
    var platform: String?

    @Argument var image: String

    func run() throws {
        var path = "/images/\(DaemonAPI.path(image))/history"
        if let platform, !platform.isEmpty {
            path += "?platform=\(DaemonAPI.query(platform))"
        }
        let items = try DaemonAPI.decode([HistoryItem].self, from: DaemonAPI.get(path))

        if quiet {
            for item in items where item.Id != "<missing>" {
                print(noTrunc ? item.Id : Format.shortID(item.Id))
            }
            return
        }

        let rows: [[(String, String)]] = items.map { item in
            [
                ("ID", noTrunc ? item.Id : Format.shortID(item.Id)),
                ("CreatedSince", human ? Format.timeAgo(item.Created) : String(item.Created)),
                ("CreatedAt", Format.createdAt(item.Created)),
                ("CreatedBy", Format.createdBy(item.CreatedBy ?? "", truncating: !noTrunc)),
                ("Size", human ? Format.size(item.Size) : String(item.Size)),
                ("Comment", item.Comment ?? ""),
            ]
        }
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, rows: rows)
            return
        }
        Table.print(headers: ["IMAGE", "CREATED", "CREATED BY", "SIZE", "COMMENT"], rows: rows.map {
            [$0[0].1, $0[1].1, $0[3].1, $0[4].1, $0[5].1]
        })
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search Docker Hub for images.")
    @Argument var term: String
    @Option var limit: Int = 25

    @Flag(help: "Don't truncate output.")
    var noTrunc = false

    @Option(name: [.customShort("f"), .long], help: "Filter output (e.g. 'stars=3', 'is-official=true').")
    var filter: [String] = []

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    func run() throws {
        var query = ["term=\(DaemonAPI.query(term))", "limit=\(limit)"]
        if !filter.isEmpty {
            query.append("filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(filter)))")
        }
        let items = try DaemonAPI.decode(
            [SearchItem].self,
            from: DaemonAPI.get("/images/search?\(query.joined(separator: "&"))")
        )

        let rows: [[(String, String)]] = items.map { item in
            let description = item.description ?? ""
            return [
                ("Name", item.name),
                ("Description", noTrunc ? description : Format.ellipsis(description)),
                ("StarCount", String(item.star_count)),
                ("IsOfficial", item.is_official ? "[OK]" : ""),
                ("IsAutomated", (item.is_automated ?? false) ? "[OK]" : ""),
            ]
        }
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, rows: rows)
            return
        }
        Table.print(headers: ["NAME", "DESCRIPTION", "STARS", "OFFICIAL"], rows: rows.map {
            [$0[0].1, $0[1].1, $0[2].1, $0[3].1]
        })
    }
}

struct ImagePrune: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove unused images.")

    @Flag(name: .shortAndLong, help: "Remove all unused images, not just dangling ones.")
    var all = false

    @Flag(name: [.customShort("f"), .long], help: "Do not prompt for confirmation.")
    var force = false

    @Option(help: "Filter what to prune (e.g. 'until=24h', 'label=key=value').")
    var filter: [String] = []

    func run() throws {
        let warning = all
            ? "This will remove all images without at least one container associated to them."
            : "This will remove all dangling images."
        guard Prompt.confirm(warning, force: force) else { return }
        let filters = all ? filter + ["dangling=false"] : filter
        let result = try DaemonAPI.decode(
            ImagePruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath("/images/prune", filters: filters), timeoutSeconds: 120)
        )
        if let items = result.imagesDeleted, !items.isEmpty {
            print("Deleted Images:")
            for item in items {
                if let untagged = item.untagged { print("untagged: \(untagged)") }
                if let deleted = item.deleted { print("deleted: \(deleted)") }
            }
        }
        print("Total reclaimed space: \(Format.size(result.spaceReclaimed ?? 0))")
    }
}

struct Save: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save one or more images to a tar archive.")
    @Option(name: .shortAndLong, help: "Write to a file instead of stdout.")
    var output: String?
    @Option(help: "Save only a specific platform, e.g. linux/arm64.")
    var platform: String?
    @Argument var images: [String]

    func run() throws {
        var query = images.map { "names=\(DaemonAPI.query($0))" }
        if let platform, !platform.isEmpty {
            query.append("platform=\(DaemonAPI.query(platform))")
        }
        let response = try DaemonAPI.requireOK(DaemonAPI.get("/images/get?\(query.joined(separator: "&"))", timeoutSeconds: 120))
        if let output {
            try response.body.write(to: URL(fileURLWithPath: output))
        } else {
            try FileHandle.standardOutput.write(contentsOf: response.body)
        }
    }
}

struct Load: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Load an image from a tar archive.")
    @Option(name: .shortAndLong, help: "Read from a tar file instead of stdin.")
    var input: String?

    @Flag(name: [.customShort("q"), .long], help: "Suppress the load output.")
    var quiet = false

    // Accepted for Docker compatibility; the store always keeps the host platform.
    @Option(help: "Load only a specific platform (host platform only).")
    var platform: String?

    func run() throws {
        DaemonAPI.warnIgnoredPlatform(platform, command: "load")
        let data = if let input {
            try Data(contentsOf: URL(fileURLWithPath: input))
        } else {
            FileHandle.standardInput.readDataToEndOfFile()
        }
        let response = try DaemonAPI.requireOK(
            DaemonAPI.post("/images/load", body: data, contentType: "application/x-tar", timeoutSeconds: 120)
        )
        if !quiet, let text = String(data: response.body, encoding: .utf8), !text.isEmpty {
            print(text)
        }
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import the contents from a tarball to create a filesystem image."
    )

    @Option(name: [.customShort("c"), .customLong("change")], help: "Apply Dockerfile instruction to the created image.")
    var change: [String] = []

    @Option(name: [.customShort("m"), .customLong("message")], help: "Set commit message for imported image.")
    var message: String?

    @Option(help: "Platform of the imported image (host platform only).")
    var platform: String?

    @Argument(help: "File, URL, or - for stdin.")
    var source: String

    @Argument(help: "Name and optionally a tag in the name:tag format.")
    var repository: String?

    func run() throws {
        var query = ["fromSrc=\(DaemonAPI.query(Self.fromSrc(source)))"]
        if let repository {
            let (repo, tag) = DaemonAPI.splitReference(repository)
            query.append("repo=\(DaemonAPI.query(repo))")
            query.append("tag=\(DaemonAPI.query(tag))")
        }
        if let message, !message.isEmpty {
            query.append("message=\(DaemonAPI.query(message))")
        }
        if let platform, !platform.isEmpty {
            query.append("platform=\(DaemonAPI.query(platform))")
        }
        for instruction in change {
            query.append("changes=\(DaemonAPI.query(instruction))")
        }
        let path = "/images/create?\(query.joined(separator: "&"))"

        if Self.isRemote(source) {
            try DaemonAPI.streamProgress(path: path)
            return
        }

        let tar = try Self.localArchive(source)
        defer {
            if source == "-" { try? FileManager.default.removeItem(at: tar) }
        }
        try DaemonAPI.streamProgress(path: path, bodyFile: tar, contentType: "application/x-tar")
    }

    private static func isRemote(_ source: String) -> Bool {
        source.hasPrefix("http://") || source.hasPrefix("https://")
    }

    private static func fromSrc(_ source: String) -> String {
        isRemote(source) ? source : "-"
    }

    private static func localArchive(_ source: String) throws -> URL {
        if source != "-" {
            let url = URL(fileURLWithPath: source)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw CLIError.io("cannot read \(source)")
            }
            return url
        }
        let tar = FileManager.default.temporaryDirectory
            .appendingPathComponent("macker-import-\(UUID().uuidString).tar")
        FileManager.default.createFile(atPath: tar.path, contents: nil)
        let out = try FileHandle(forWritingTo: tar)
        defer { try? out.close() }
        while true {
            let chunk = FileHandle.standardInput.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
        }
        return tar
    }
}

struct ImageGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manage images.",
        subcommands: [
            ImageLs.self, ImageList.self, Build.self, Pull.self, ImageRm.self, Tag.self, Push.self, History.self, ImageInspect.self,
            ImagePrune.self, Save.self, Load.self, Import.self,
        ]
    )
}

struct ImageLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List images.")

    @OptionGroup var options: ImageListOptions

    func run() throws {
        try Images.list(
            all: options.all,
            quiet: options.quiet,
            digests: options.digests,
            noTrunc: options.noTrunc,
            filters: options.filter,
            format: options.format
        )
    }
}

struct ImageList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List images.", shouldDisplay: false)
    @OptionGroup var options: ImageListOptions
    func run() throws {
        try Images.list(
            all: options.all,
            quiet: options.quiet,
            digests: options.digests,
            noTrunc: options.noTrunc,
            filters: options.filter,
            format: options.format
        )
    }
}

struct ImageRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more images.")

    @Flag(name: [.customShort("f"), .long], help: "Force removal of the image.")
    var force = false

    @Flag(help: "Do not delete untagged parent layers.")
    var noPrune = false

    @Argument var images: [String]

    func run() throws { try Rmi.remove(images, force: force, noPrune: noPrune) }
}

struct ImageInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more images.")
    @Argument var images: [String]
    func run() throws { try Inspect.inspect(images, prefer: .image) }
}

private struct ImageSummary: Decodable {
    var Id: String
    var RepoTags: [String]?
    var RepoDigests: [String]?
    var Created: Int64?
    var Size: Int64
}

private struct HistoryItem: Decodable {
    var Id: String
    var Created: Int64
    var CreatedBy: String?
    var Size: Int64
    var Comment: String?
}

private struct SearchItem: Decodable {
    var name: String
    var description: String?
    var star_count: Int
    var is_official: Bool
    var is_automated: Bool?
}
