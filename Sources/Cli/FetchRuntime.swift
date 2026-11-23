import ArgumentParser
import ContainerEngine
import Foundation

struct FetchRuntime: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch-runtime",
        abstract: "Download the pinned guest kernel and vminit into the daemon store (stop the daemon first)."
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
            try await RuntimeAssets.fetch(output: output.map { URL(fileURLWithPath: $0, isDirectory: true) })
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
