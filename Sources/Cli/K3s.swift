import ArgumentParser
import ContainerEngine
import Darwin
import Foundation

struct K3s: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "k3s", abstract: "Manage the experimental local K3s node.",
        subcommands: [Start.self, Status.self, Stop.self, Kubeconfig.self, Image.self, Reset.self]
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the MicroVM (the Kubernetes API may still be initializing).")
        @Flag(help: "Wait for the Kubernetes API and node to be Ready.")
        var wait = false

        func run() throws {
            let path = wait ? "/macker/k3s/start?wait=1" : "/macker/k3s/start"
            let response = try DaemonAPI.post(path, timeoutSeconds: wait ? 450 : 300)
            let port = try DaemonAPI.decode(EnginePortBinding.self, from: response)
            print("https://\(port.joinedHostPort)")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the VM and Kubernetes readiness state.")
        func run() throws {
            let status = try DaemonAPI.decode(K3sStatus.self, from: DaemonAPI.get("/macker/k3s/status", timeoutSeconds: 15))
            print(status.state)
            if let endpoint = status.endpoint { print("API: \(endpoint)") }
            if let detail = status.detail { print(detail) }
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a stopped cluster and all of its data.")
        @Flag(help: "Confirm permanent deletion of cluster data.")
        var confirm = false

        func run() throws {
            guard confirm else { throw ValidationError("reset deletes all cluster data; pass --confirm to proceed") }
            try DaemonAPI.requireOK(DaemonAPI.delete("/macker/k3s?confirm=1"))
        }
    }

    struct Image: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage local images in K3s.", subcommands: [Sync.self])

        struct Sync: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Sync an existing local image tag without pulling or rebuilding.")
            @Argument(help: "Local image tag, for example demo:dev.")
            var reference: String

            func run() throws {
                try K3s.syncImage(tags: [reference])
            }
        }
    }

    static func syncImage(digest: String? = nil, tags: [String]) throws {
        struct SyncRequest: Encodable {
            let imageID: String?
            let tags: [String]
        }
        let body = try JSONEncoder().encode(SyncRequest(imageID: digest, tags: tags))
        try DaemonAPI.requireOK(DaemonAPI.post("/macker/k3s/images/sync", body: body, timeoutSeconds: nil))
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the MicroVM and keep cluster data.")
        func run() throws {
            try DaemonAPI.requireOK(DaemonAPI.post("/macker/k3s/stop", timeoutSeconds: 45))
        }
    }

    struct Kubeconfig: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write an admin kubeconfig to a new private file.")
        @Argument(help: "New output path. Existing files are never overwritten.")
        var path: String

        func run() throws {
            let config = try DaemonAPI.decode(String.self, from: DaemonAPI.post("/macker/k3s/kubeconfig", timeoutSeconds: 15))
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw CLIError.io("cannot create kubeconfig: \(String(cString: strerror(errno)))")
            }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try file.write(contentsOf: Data(config.utf8))
                try file.close()
            } catch {
                try? file.close()
                throw error
            }
        }
    }
}
