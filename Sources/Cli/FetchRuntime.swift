import ArgumentParser
import ContainerEngine
import Foundation

struct FetchRuntime: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch-runtime",
        abstract: "Download the pinned guest kernel and vminit into the daemon store."
    )

    @Option(name: .shortAndLong, help: "Also copy vmlinux and initfs.ext4 here for packaging.")
    var output: String?

    func run() throws {
        let pin = RuntimePin.current
        print("Macker \(ProductVersion.current)")
        print("  containerization \(pin.containerization)")
        print("  kata             \(pin.kata)")
        print("  vminit           \(pin.vminitReference)")
        print("")

        let status = try RunSync.call {
            let engine = try EngineManager()
            if let output {
                return try await engine.stageRuntime(to: URL(fileURLWithPath: output, isDirectory: true))
            }
            return try await engine.prepareRuntime()
        }
        if let kernel = status.kernelPath {
            print("  [ok  ] kernel \(kernel)")
        }
        if let initfs = status.initfsPath {
            print("  [ok  ] initfs \(initfs)")
        }
        if let output {
            print("  [ok  ] staged \(output)/vmlinux")
            print("  [ok  ] staged \(output)/initfs.ext4")
        }
    }
}
