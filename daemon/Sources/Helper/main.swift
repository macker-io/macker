import Darwin
import Foundation
import MackerHelperSupport

signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
guard args.isEmpty || args == ["serve"] else {
    fputs("usage: macker-helper serve\n", stderr)
    exit(2)
}

do {
    try HelperServer.run()
} catch {
    fputs("macker-helper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
