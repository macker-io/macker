import ArgumentParser
import ContainerEngine
import Foundation

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a container's filesystem as a tar archive.")

    @Option(name: .shortAndLong, help: "Write to a file instead of stdout.")
    var output: String?

    @Argument var container: String

    func run() throws { try Self.export(container, output: output) }

    static func export(_ container: String, output: String?) throws {
        let response = try DaemonAPI.requireOK(
            DaemonAPI.get("/containers/\(DaemonAPI.path(container))/export", timeoutSeconds: 300)
        )
        if let output {
            try response.body.write(to: URL(fileURLWithPath: output))
        } else {
            try FileHandle.standardOutput.write(contentsOf: response.body)
        }
    }
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect changes to files or directories on a container's filesystem.")

    @Argument var container: String

    func run() throws { try Self.diff(container) }

    static func diff(_ container: String) throws {
        let changes = try DaemonAPI.decode(
            [FilesystemChange].self,
            from: DaemonAPI.get("/containers/\(DaemonAPI.path(container))/changes", timeoutSeconds: 120)
        )
        for change in changes {
            let letter = EngineFSChange.Kind(rawValue: change.Kind)?.letter ?? "C"
            print("\(letter) \(change.Path)")
        }
    }
}

struct Commit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new image from a container's changes.")

    @Option(name: .shortAndLong, help: "Author (e.g., \"Name <email@example.com>\").")
    var author: String?

    @Option(name: .shortAndLong, help: "Apply Dockerfile instruction to the created image.")
    var change: [String] = []

    @Option(name: [.customShort("m"), .customLong("message")], help: "Commit message.")
    var message: String?

    @Option(name: .shortAndLong, help: "Pause container during commit (ignored; snapshot goes through the guest).")
    var pause: Bool = true

    @Argument var container: String
    @Argument var repository: String?

    func run() throws {
        _ = pause
        try Self.commit(
            container,
            repository: repository,
            author: author,
            message: message,
            changes: change
        )
    }

    static func commit(
        _ container: String,
        repository: String?,
        author: String?,
        message: String?,
        changes: [String]
    ) throws {
        var query = ["container=\(DaemonAPI.query(container))"]
        if let repository {
            let (repo, tag) = DaemonAPI.splitReference(repository)
            query.append("repo=\(DaemonAPI.query(repo))")
            query.append("tag=\(DaemonAPI.query(tag))")
        }
        if let author, !author.isEmpty {
            query.append("author=\(DaemonAPI.query(author))")
        }
        if let message, !message.isEmpty {
            query.append("comment=\(DaemonAPI.query(message))")
        }
        for instruction in changes {
            query.append("changes=\(DaemonAPI.query(instruction))")
        }
        let response = try DaemonAPI.decode(
            CommitResponse.self,
            from: DaemonAPI.post("/commit?\(query.joined(separator: "&"))", timeoutSeconds: 300)
        )
        print(response.Id)
    }
}

private struct FilesystemChange: Decodable {
    var Path: String
    var Kind: Int
}

private struct CommitResponse: Decodable {
    var Id: String
}
