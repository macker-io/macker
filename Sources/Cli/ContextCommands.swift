import ArgumentParser
import Foundation

struct ContextGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Manage contexts.",
        subcommands: [
            ContextLs.self, ContextCreate.self, ContextUse.self, ContextShow.self, ContextInspect.self,
            ContextRm.self, ContextUpdate.self, ContextExport.self, ContextImport.self,
        ]
    )
}

struct ContextLs: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List contexts.")

    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template.")
    var format: String?

    @Flag(name: [.customShort("q"), .long], help: "Only show context names.")
    var quiet = false

    func run() throws {
        let current = ContextStore.currentName()
        let contexts = try ContextStore.list()
        if quiet {
            for context in contexts { print(context.name) }
            return
        }
        if let format, !FormatTemplate.isBareTable(format) {
            let rows: [[(String, String)]] = contexts.map { context in
                [
                    ("Name", context.name == current ? "\(context.name) *" : context.name),
                    ("Description", context.description),
                    ("DockerEndpoint", context.host),
                    ("Current", context.name == current ? "true" : "false"),
                ]
            }
            try FormatTemplate.print(format: format, rows: rows)
            return
        }
        Table.print(
            headers: ["NAME", "DESCRIPTION", "DOCKER ENDPOINT"],
            rows: contexts.map { context in
                [
                    context.name == current ? "\(context.name) *" : context.name,
                    context.description,
                    context.host,
                ]
            }
        )
    }
}

struct ContextCreate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a context.")

    @Option(help: "Description of the context.")
    var description: String = ""

    @Option(name: .customLong("docker"), help: "Docker endpoint, e.g. host=unix:///path/macker.sock.")
    var docker: [String] = []

    @Option(name: .customLong("from"), help: "Create from an existing context.")
    var from: String?

    @Argument var name: String

    func run() throws {
        let endpoint = try ContextStore.endpoint(from: docker)
        let base = try from.map { try ContextStore.load($0) }
        let host = endpoint.host ?? base?.host ?? ContextStore.defaultContext().host
        let context = DockerContext(
            name: name,
            description: description.isEmpty ? (base?.description ?? "") : description,
            host: host,
            skipTLSVerify: endpoint.skipTLSVerify ?? base?.skipTLSVerify ?? false
        )
        try ContextStore.create(context)
        print(name)
    }
}

struct ContextUse: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use", abstract: "Set the current context.")
    @Argument var name: String
    func run() throws {
        try ContextStore.setCurrent(name)
        print(name)
    }
}

struct ContextShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the name of the current context.")
    func run() throws {
        print(ContextStore.currentName())
    }
}

struct ContextInspect: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on one or more contexts.")
    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template.")
    var format: String?
    @Argument var names: [String] = []

    func run() throws {
        let names = names.isEmpty ? [ContextStore.currentName()] : names
        let objects: [[String: Any]] = try names.map { name in
            try ContextStore.load(name).metaJSON
        }
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, objects: objects)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
        if let text = String(data: data, encoding: .utf8) { print(text) }
    }
}

struct ContextRm: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more contexts.")
    @Flag(name: .shortAndLong, help: "Force removal of a context in use.")
    var force = false
    @Argument var names: [String]
    func run() throws {
        for name in names {
            try ContextStore.remove(name, force: force)
            print(name)
        }
    }
}

struct ContextUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a context.")
    @Option(help: "Description of the context.")
    var description: String?
    @Option(name: .customLong("docker"), help: "Docker endpoint, e.g. host=unix:///path/macker.sock.")
    var docker: [String] = []
    @Argument var name: String
    func run() throws {
        let endpoint = try ContextStore.endpoint(from: docker)
        try ContextStore.update(
            name: name,
            description: description,
            host: endpoint.host,
            skipTLSVerify: endpoint.skipTLSVerify
        )
    }
}

struct ContextExport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Export a context to a tar file.")
    @Argument var name: String
    @Argument var file: String = "-"
    func run() throws {
        try ContextStore.exportTar(name, to: file == "-" ? nil : URL(fileURLWithPath: file))
    }
}

struct ContextImport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import", abstract: "Import a context from a tar file.")
    @Argument var name: String
    @Argument var file: String = "-"
    func run() throws {
        try ContextStore.importTar(name: name, from: file == "-" ? nil : URL(fileURLWithPath: file))
        print(name)
    }
}
