import ArgumentParser
import ContainerEngine
import Darwin
import Foundation

struct K3s: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "k3s", abstract: "Manage the experimental local K3s node.",
        subcommands: [Start.self, Stop.self, Kubeconfig.self]
    )

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the MicroVM (the Kubernetes API may still be initializing).")
        func run() throws {
            let port = try DaemonAPI.decode(EnginePortBinding.self, from: DaemonAPI.post("/macker/k3s/start", timeoutSeconds: 300))
            print("https://\(port.joinedHostPort)")
        }
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
