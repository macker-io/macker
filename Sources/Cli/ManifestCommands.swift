import ArgumentParser
import Foundation

struct ManifestGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Manage Docker image manifests and manifest lists.",
        subcommands: [
            ManifestInspect.self, ManifestCreate.self, ManifestAnnotate.self, ManifestPush.self, ManifestRm.self,
        ]
    )
}

struct ManifestInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display an image manifest, or manifest list.")

    @Flag(name: .customLong("insecure"), help: "Allow communication with an insecure registry.")
    var insecure = false

    @Flag(name: .shortAndLong, help: "Output additional info including layers and platform.")
    var verbose = false

    @Argument var name: String

    func run() throws {
        var path = "/distribution/\(DaemonAPI.path(name))/json?manifest=1"
        if insecure { path += "&insecure=1" }
        let response = try DaemonAPI.requireOK(DaemonAPI.get(path, timeoutSeconds: 60))
        if verbose {
            let mediaType = response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? ""
            let wrapped: [String: Any] = [
                "Ref": name,
                "Descriptor": [
                    "MediaType": mediaType,
                ],
                "SchemaV2Manifest": try JSONSerialization.jsonObject(with: response.body),
            ]
            let data = try JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys])
            if let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        try DaemonAPI.printJSON(response.body)
    }
}

struct ManifestCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a local manifest list.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var list: String
    func run() throws { throw CLIError.io("manifest lists are not implemented") }
}

struct ManifestAnnotate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "annotate", abstract: "Add additional information to a local image manifest.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var list: String
    @Argument var manifest: String
    func run() throws { throw CLIError.io("manifest lists are not implemented") }
}

struct ManifestPush: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Push a manifest list to a repository.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var list: String
    func run() throws { throw CLIError.io("manifest lists are not implemented") }
}

struct ManifestRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete one or more manifest lists from local storage.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var lists: [String]
    func run() throws { throw CLIError.io("manifest lists are not implemented") }
}
