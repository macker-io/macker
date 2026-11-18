import CliCore

// ArgumentParser's `main(_:)` does not drop argv0, unlike `main()`.
let arguments = DockerGlobalFlags.install(from: CommandLine.arguments)
Macker.main(Array(arguments.dropFirst()))
