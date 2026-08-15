import Containerization
import ContainerizationError
import Foundation

/// Guest kernel + initfs locations used to boot a MicroVM.
public struct RuntimeStatus: Sendable {
    public let kernelPath: String?
    public let initfsPath: String?
    public let vminitReference: String
    public let vminitPresent: Bool

    public var isReady: Bool {
        kernelPath != nil && (initfsPath != nil || vminitPresent)
    }
}

/// Resolves (and optionally downloads) the Linux kernel and vminit initfs.
///
/// The daemon store (`~/Library/Application Support/io.macker.daemon`) is the
/// runtime location. `daemon/.runtime` is only a packaging cache.
enum RuntimeAssets {
    static var vminitReference: String {
        let env = ProcessInfo.processInfo.environment["MACKER_VMINIT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return env.isEmpty ? RuntimePin.current.vminitReference : env
    }

    static func inspect(storePath: URL, vminitPresent: Bool) -> RuntimeStatus {
        RuntimeStatus(
            kernelPath: firstExisting(kernelCandidates(storePath: storePath))?.path,
            initfsPath: firstExisting(initfsCandidates(storePath: storePath))?.path,
            vminitReference: vminitReference,
            vminitPresent: vminitPresent
        )
    }

    static func prepare(
        store: ImageStore,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RuntimeStatus {
        let kernel = try await ensureKernel(storePath: store.path, onProgress: onProgress)
        let initfs = try await ensureInitfs(store: store, onProgress: onProgress)
        let images = (try? await store.list()) ?? []
        let vminitPresent = images.contains { $0.reference.contains("vminit") }
        return RuntimeStatus(
            kernelPath: kernel.path,
            initfsPath: initfs.path,
            vminitReference: vminitReference,
            vminitPresent: vminitPresent
        )
    }

    static func kernel(storePath: URL) throws -> Kernel {
        guard let path = firstExisting(kernelCandidates(storePath: storePath)) else {
            throw EngineError.runtimeUnavailable(
                "Linux kernel not found. Run `macker fetch-runtime` or set MACKER_KERNEL."
            )
        }
        return Kernel(path: path, platform: .linuxArm)
    }

    static func initfsMount(storePath: URL) throws -> Mount {
        guard let path = firstExisting(initfsCandidates(storePath: storePath)) else {
            throw EngineError.runtimeUnavailable(
                "initfs not found. Run `macker fetch-runtime` or set MACKER_INITFS."
            )
        }
        return .block(format: "ext4", source: path.path, destination: "/", options: ["ro"])
    }

    private static func storeKernelURL(storePath: URL) -> URL {
        storePath.appendingPathComponent("runtime", isDirectory: true).appendingPathComponent("vmlinux")
    }

    private static func storeInitfsURL(storePath: URL) -> URL {
        storePath.appendingPathComponent("initfs.ext4")
    }

    private static func ensureKernel(
        storePath: URL,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let destination = storeKernelURL(storePath: storePath)
        if isUsableFile(destination) {
            return destination
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let existing = firstExisting(kernelCandidates(storePath: storePath)) {
            onProgress?("Installing kernel into the daemon store…")
            try replaceFile(at: destination, with: existing)
            guard isRegularFile(destination) else {
                throw EngineError.runtimeUnavailable("kernel install left a non-regular file at \(destination.path)")
            }
            return destination
        }

        onProgress?("Downloading Kata \(RuntimePin.current.kata) kernel…")
        try await downloadAndExtractKernel(to: destination)
        guard isRegularFile(destination) else {
            throw EngineError.runtimeUnavailable("kernel install left a non-regular file at \(destination.path)")
        }
        onProgress?("Kernel installed at \(destination.path)")
        return destination
    }

    private static func ensureInitfs(
        store: ImageStore,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let initPath = storeInitfsURL(storePath: store.path)
        if isUsableFile(initPath) {
            return initPath
        }

        if let existing = firstExisting(initfsCandidates(storePath: store.path)) {
            onProgress?("Installing initfs into the daemon store…")
            try replaceFile(at: initPath, with: existing)
            return initPath
        }

        onProgress?("Pulling \(vminitReference)…")
        let initImage = try await store.getInitImage(reference: vminitReference)
        onProgress?("Unpacking initfs…")
        do {
            _ = try await initImage.initBlock(at: initPath, for: .linuxArm)
        } catch let error as ContainerizationError where error.code == .exists {
            // A previous unpack left the block file in place.
        }
        guard isUsableFile(initPath) else {
            throw EngineError.runtimeUnavailable("failed to unpack initfs at \(initPath.path)")
        }
        onProgress?("initfs ready at \(initPath.path)")
        return initPath
    }

    private static func downloadAndExtractKernel(to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: RuntimePin.current.kataArchiveURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EngineError.runtimeUnavailable("kernel download failed: HTTP \(http.statusCode)")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("macker-kernel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent("kata.tar.xz")
        try removeIfPresent(archive)
        try FileManager.default.moveItem(at: tempURL, to: archive)

        let extract = work.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        try runTar(archive: archive, directory: extract)

        guard let kernel = findFile(named: "vmlinux.container", under: extract)
            ?? findFilePrefix("vmlinux", under: extract)
        else {
            throw EngineError.runtimeUnavailable("kata archive did not contain a vmlinux kernel")
        }

        try replaceFile(at: destination, with: kernel)
    }

    private static func runTar(archive: URL, directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", directory.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw EngineError.runtimeUnavailable("tar failed: \(detail)")
        }
    }

    /// Copies the store kernel and initfs into `output` for app/pkg packaging.
    static func stage(status: RuntimeStatus, to output: URL) throws {
        guard let kernel = status.kernelPath else {
            throw EngineError.runtimeUnavailable("kernel is not available to stage")
        }
        guard let initfs = status.initfsPath else {
            throw EngineError.runtimeUnavailable("initfs is not available to stage")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try replaceFile(at: output.appendingPathComponent("vmlinux"), with: URL(fileURLWithPath: kernel))
        try replaceFile(at: output.appendingPathComponent("initfs.ext4"), with: URL(fileURLWithPath: initfs))
        if let pin = RuntimePin.jsonURL {
            try replaceFile(at: output.appendingPathComponent("RuntimePin.json"), with: pin)
        }
    }

    /// Store first, then a packaged `.app`, then the checkout cache, then vendor.
    private static func kernelCandidates(storePath: URL) -> [URL] {
        var paths: [URL] = []
        if let env = envURL("MACKER_KERNEL") {
            paths.append(env)
        }
        paths.append(storeKernelURL(storePath: storePath))
        for directory in RuntimePin.bundledRuntimeDirectories() {
            paths.append(directory.appendingPathComponent("vmlinux"))
        }
        paths.append(RuntimePin.checkoutRuntimeDirectory.appendingPathComponent("vmlinux"))
        paths.append(vendorRoot.appendingPathComponent("bin/vmlinux-arm64"))
        paths.append(vendorRoot.appendingPathComponent(".local/vmlinux-arm64"))
        return paths
    }

    private static func initfsCandidates(storePath: URL) -> [URL] {
        var paths: [URL] = []
        if let env = envURL("MACKER_INITFS") {
            paths.append(env)
        }
        paths.append(storeInitfsURL(storePath: storePath))
        paths.append(storePath.appendingPathComponent("runtime", isDirectory: true).appendingPathComponent("initfs.ext4"))
        for directory in RuntimePin.bundledRuntimeDirectories() {
            paths.append(directory.appendingPathComponent("initfs.ext4"))
        }
        paths.append(RuntimePin.checkoutRuntimeDirectory.appendingPathComponent("initfs.ext4"))
        paths.append(vendorRoot.appendingPathComponent("bin/initfs.ext4"))
        return paths
    }

    private static func envURL(_ key: String) -> URL? {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : URL(fileURLWithPath: value)
    }

    private static func firstExisting(_ urls: [URL]) -> URL? {
        urls.first(where: isUsableFile)
    }

    /// Follows a valid symlink; rejects dangling `vmlinux -> vmlinux-*` leftovers.
    private static func isUsableFile(_ url: URL) -> Bool {
        isRegularFile(url.resolvingSymlinksInPath())
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        if isSymlink(url) { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) || isSymlink(url) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Copies the resolved regular file. `copyItem` of a symlink would recreate the broken link.
    private static func replaceFile(at destination: URL, with source: URL) throws {
        let resolved = source.resolvingSymlinksInPath()
        guard isRegularFile(resolved) else {
            throw EngineError.runtimeUnavailable("refusing to install non-regular file \(source.path)")
        }
        try removeIfPresent(destination)
        try FileManager.default.copyItem(at: resolved, to: destination)
        guard isRegularFile(destination) else {
            throw EngineError.runtimeUnavailable("install produced a symlink at \(destination.path)")
        }
    }

    private static func findFile(named name: String, under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name, isUsableFile(url) {
                return url.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    private static func findFilePrefix(_ prefix: String, under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            if isSymlink(url) { continue }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile, url.lastPathComponent.hasPrefix(prefix) {
                return url
            }
        }
        return nil
    }

    private static var vendorRoot: URL {
        RuntimePin.daemonRoot.appendingPathComponent("Vendor/containerization", isDirectory: true)
    }
}
