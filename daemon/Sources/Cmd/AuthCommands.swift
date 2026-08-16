import ArgumentParser
import ContainerEngine
import Darwin
import Foundation

struct Login: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Log in to a registry.")

    @Option(name: .shortAndLong, help: "Username")
    var username: String?

    @Option(name: .shortAndLong, help: "Password")
    var password: String?

    @Flag(name: .customLong("password-stdin"), help: "Take the password from stdin.")
    var passwordStdin = false

    @Argument(help: "Registry server (default https://index.docker.io/v1/).")
    var server: String?

    func run() throws {
        var username = self.username ?? ""
        var password = self.password ?? ""

        if passwordStdin {
            guard !username.isEmpty else {
                throw CLIError.io("Must provide --username with --password-stdin")
            }
            password = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else if self.password != nil {
            fputs("WARNING! Using --password via the CLI is insecure. Use --password-stdin.\n", stderr)
        }

        if username.isEmpty {
            fputs("Username: ", stdout)
            fflush(stdout)
            username = readLine() ?? ""
        }
        if password.isEmpty {
            password = Prompt.secret("Password: ")
        }
        guard !username.isEmpty, !password.isEmpty else {
            throw CLIError.io("Username and password required")
        }

        let body = try JSONEncoder().encode(
            AuthConfig(username: username, password: password, serveraddress: server)
        )
        do {
            _ = try DaemonAPI.requireOK(DaemonAPI.post("/auth", body: body, timeoutSeconds: 60))
        } catch {
            try DaemonAPI.exitWithDaemonError(error)
        }
        print("Login Succeeded")
    }
}

struct Logout: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Log out from a registry.")

    @Argument(help: "Registry server (default https://index.docker.io/v1/).")
    var server: String?

    func run() throws {
        let address = server ?? "https://index.docker.io/v1/"
        var path = "/auth"
        if let server, !server.isEmpty {
            path += "?serveraddress=\(DaemonAPI.query(server))"
        }
        do {
            _ = try DaemonAPI.requireOK(DaemonAPI.delete(path))
        } catch {
            try DaemonAPI.exitWithDaemonError(error)
        }
        print("Removing login credentials for \(address)")
    }
}
