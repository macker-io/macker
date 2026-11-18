import ArgumentParser
import Foundation

struct TrustGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "Manage trust on Docker images.",
        subcommands: [TrustInspect.self, TrustSign.self, TrustRevoke.self, TrustKey.self, TrustSigner.self]
    )
}

struct TrustInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Return low-level information about keys and signatures.")
    @Flag(name: .customLong("pretty"), help: "Print the information in a human friendly format.")
    var pretty = false
    @Argument var images: [String]

    func run() throws {
        for image in images {
            let path = "/distribution/\(DaemonAPI.path(image))/json"
            let response = try DaemonAPI.requireOK(DaemonAPI.get(path, timeoutSeconds: 60))
            let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            let digest = (object?["Descriptor"] as? [String: Any])?["digest"] as? String ?? ""
            if pretty {
                print("No signatures for \(image)")
                if !digest.isEmpty { print("Digest: \(digest)") }
            } else {
                let payload: [[String: Any]] = [[
                    "Name": image,
                    "SignedTags": [] as [String],
                    "Signers": [] as [String],
                    "AdministrativeKeys": [] as [String],
                    "Digest": digest,
                ]]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                if let text = String(data: data, encoding: .utf8) { print(text) }
            }
        }
        fputs("content trust signatures are not implemented\n", stderr)
    }
}

struct TrustSign: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sign", abstract: "Sign an image.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var image: String
    func run() throws { throw CLIError.io("content trust is not implemented") }
}

struct TrustRevoke: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Remove trust for an image.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var image: String
    func run() throws { throw CLIError.io("content trust is not implemented") }
}

struct TrustKey: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Manage keys for signing Docker images.",
        subcommands: [TrustKeyGenerate.self, TrustKeyLoad.self]
    )
}

struct TrustKeyGenerate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "generate", abstract: "Generate and load a signing key-pair.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var name: String
    func run() throws { throw CLIError.io("content trust is not implemented") }
}

struct TrustKeyLoad: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "load", abstract: "Load a private key file for signing.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var key: String
    @Argument var name: String = ""
    func run() throws { throw CLIError.io("content trust is not implemented") }
}

struct TrustSigner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signer",
        abstract: "Manage entities who can sign Docker images.",
        subcommands: [TrustSignerAdd.self, TrustSignerRemove.self]
    )
}

struct TrustSignerAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a signer.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var name: String
    @Argument var repository: String
    func run() throws { throw CLIError.io("content trust is not implemented") }
}

struct TrustSignerRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a signer.")
    @OptionGroup var ignored: IgnoredDockerFlags
    @Argument var name: String
    @Argument var repository: String
    func run() throws { throw CLIError.io("content trust is not implemented") }
}
