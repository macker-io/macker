import ArgumentParser
import Foundation

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pull an image from a registry.")

    @Argument(help: "Image reference, e.g. alpine or hello-world:latest.")
    var image: String

    @Option(help: "Platform, e.g. linux/arm64.")
    var platform: String?

    func run() throws {
        let (name, tag) = DaemonAPI.splitReference(image)
        var path = "/images/create?fromImage=\(DaemonAPI.query(name))&tag=\(DaemonAPI.query(tag))"
        if let platform, !platform.isEmpty {
            path += "&platform=\(DaemonAPI.query(platform))"
        }
        try DaemonAPI.streamProgress(path: path)
    }
}

struct Push: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Push an image to a registry.")
    @Argument var image: String

    func run() throws {
        let (name, tag) = DaemonAPI.splitReference(image)
        try DaemonAPI.streamProgress(path: "/images/\(DaemonAPI.path(name))/push?tag=\(DaemonAPI.query(tag))")
    }
}

struct Images: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List images.")

    func run() throws { try Self.list() }

    static func list() throws {
        let images = try DaemonAPI.decode([ImageSummary].self, from: DaemonAPI.get("/images/json"))
        var rows: [[String]] = []
        for image in images {
            let tags = image.RepoTags?.filter { !$0.isEmpty } ?? []
            if tags.isEmpty {
                rows.append(["<none>", "<none>", Format.shortID(image.Id), Format.size(image.Size)])
                continue
            }
            for tag in tags {
                let (repo, nameTag) = splitRepoTag(tag)
                rows.append([repo, nameTag, Format.shortID(image.Id), Format.size(image.Size)])
            }
        }
        Table.print(headers: ["REPOSITORY", "TAG", "IMAGE ID", "SIZE"], rows: rows)
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
    @Argument var images: [String]
    func run() throws { try Self.remove(images) }

    static func remove(_ images: [String]) throws {
        for image in images {
            let response = try DaemonAPI.requireOK(DaemonAPI.delete("/images/\(DaemonAPI.path(image))"))
            guard let items = try? JSONDecoder().decode([ImageDeleteItem].self, from: response.body) else { continue }
            for item in items {
                if let untagged = item.Untagged { print("Untagged: \(untagged)") }
                if let deleted = item.Deleted { print("Deleted: \(deleted)") }
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
    @Argument var image: String

    func run() throws {
        let items = try DaemonAPI.decode([HistoryItem].self, from: DaemonAPI.get("/images/\(DaemonAPI.path(image))/history"))
        let rows = items.map { item in
            [Format.shortID(item.Id), item.CreatedBy ?? "", Format.size(item.Size), item.Comment ?? ""]
        }
        Table.print(headers: ["IMAGE", "CREATED BY", "SIZE", "COMMENT"], rows: rows)
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search Docker Hub for images.")
    @Argument var term: String
    @Option var limit: Int = 25

    func run() throws {
        let items = try DaemonAPI.decode(
            [SearchItem].self,
            from: DaemonAPI.get("/images/search?term=\(DaemonAPI.query(term))&limit=\(limit)")
        )
        let rows = items.map { item in
            [item.name, item.description ?? "", String(item.star_count), item.is_official ? "[OK]" : ""]
        }
        Table.print(headers: ["NAME", "DESCRIPTION", "STARS", "OFFICIAL"], rows: rows)
    }
}

struct ImagePrune: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune", abstract: "Remove unused images.")
    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation.")
    var force = false

    func run() throws {
        guard Prompt.confirm("This will remove dangling images.", force: force) else { return }
        try DaemonAPI.printJSON(try DaemonAPI.requireOK(DaemonAPI.post("/images/prune")).body)
    }
}

struct Save: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save one or more images to a tar archive.")
    @Option(name: .shortAndLong, help: "Write to a file instead of stdout.")
    var output: String?
    @Argument var images: [String]

    func run() throws {
        let query = images.map { "names=\(DaemonAPI.query($0))" }.joined(separator: "&")
        let response = try DaemonAPI.requireOK(DaemonAPI.get("/images/get?\(query)", timeoutSeconds: 120))
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

    func run() throws {
        let data = if let input {
            try Data(contentsOf: URL(fileURLWithPath: input))
        } else {
            FileHandle.standardInput.readDataToEndOfFile()
        }
        let response = try DaemonAPI.requireOK(
            DaemonAPI.post("/images/load", body: data, contentType: "application/x-tar", timeoutSeconds: 120)
        )
        if let text = String(data: response.body, encoding: .utf8), !text.isEmpty {
            print(text)
        }
    }
}

struct ImageGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manage images.",
        subcommands: [ImageLs.self, Pull.self, ImageRm.self, Tag.self, Push.self, History.self, ImageInspect.self, ImagePrune.self]
    )
}

struct ImageLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List images.")
    func run() throws { try Images.list() }
}

struct ImageRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more images.")
    @Argument var images: [String]
    func run() throws { try Rmi.remove(images) }
}

struct ImageInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more images.")
    @Argument var images: [String]
    func run() throws { try Inspect.inspect(images, prefer: .image) }
}

private struct ImageSummary: Decodable {
    var Id: String
    var RepoTags: [String]?
    var Size: Int64
}

private struct ImageDeleteItem: Decodable {
    var Untagged: String?
    var Deleted: String?
}

private struct HistoryItem: Decodable {
    var Id: String
    var CreatedBy: String?
    var Size: Int64
    var Comment: String?
}

private struct SearchItem: Decodable {
    var name: String
    var description: String?
    var star_count: Int
    var is_official: Bool
}
