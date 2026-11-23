import ArgumentParser
import Darwin
import Foundation
import MackerTransport

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the Macker / Docker-compatible API version."
    )

    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    func run() throws {
        let response = try DaemonAPI.requireOK(DaemonAPI.get("/version"))
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(
                format: format,
                objects: [
                    [
                        "Client": Self.clientInfo(),
                        "Server": try JSONSerialization.jsonObject(with: response.body),
                    ]
                ]
            )
            return
        }
        let version = try JSONDecoder().decode(VersionInfo.self, from: response.body)
        print("Client: \(Invocation.commandName)")
        print(" Version:    \(DaemonAPI.clientVersion)")
        print(" API:        \(DaemonAPI.apiVersion)")
        print("Server:")
        print(" Version:    \(version.Version)")
        print(" API:        \(version.ApiVersion)")
        print(" OS/Arch:    \(version.Os)/\(version.Arch)")
    }

    private static func clientInfo() -> [String: Any] {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return [
            "Platform": ["Name": "macker"],
            "Version": DaemonAPI.clientVersion,
            "APIVersion": DaemonAPI.apiVersion,
            "DefaultAPIVersion": DaemonAPI.apiVersion,
            "GitCommit": "dev",
            "GoVersion": "swift-6.2",
            "Os": "darwin",
            "Arch": arch,
            "BuildTime": "",
            "Context": "default",
            "Experimental": true,
        ]
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Display system-wide information.")

    @Option(name: [.customShort("f"), .long], help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    func run() throws {
        let data = try DaemonAPI.requireOK(DaemonAPI.get("/info")).body
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, objects: [try JSONSerialization.jsonObject(with: data)])
            return
        }
        try DaemonAPI.printJSON(data)
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Get real time events from the server.")

    @Option(name: [.customShort("f"), .long], help: "Filter output based on conditions provided.")
    var filter: [String] = []

    @Option(help: "Show all events created since timestamp.")
    var since: String?

    @Option(help: "Stream events until this timestamp.")
    var until: String?

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    func run() throws {
        var query: [String] = []
        if let since { query.append("since=\(DaemonAPI.query(since))") }
        if let until { query.append("until=\(DaemonAPI.query(until))") }
        if !filter.isEmpty {
            query.append("filters=\(DaemonAPI.query(try DaemonAPI.filtersJSON(filter)))")
        }
        let path = query.isEmpty ? "/events" : "/events?\(query.joined(separator: "&"))"
        let template: FormatTemplate.Template?
        if let format, !FormatTemplate.isBareTable(format) {
            template = try FormatTemplate.parse(format)
        } else {
            template = nil
        }
        var headerPrinted = false
        var failed: Error?
        let status = try DaemonAPI.streamLines(method: "GET", path: path, timeoutSeconds: nil) { line in
            guard failed == nil, !line.isEmpty else { return }
            do {
                try Self.emit(line, template: template, headerPrinted: &headerPrinted)
            } catch {
                failed = error
            }
        }
        if let failed { throw failed }
        if status >= 400 {
            throw CLIError.http("events failed with HTTP \(status)")
        }
    }

    private static func emit(
        _ line: String,
        template: FormatTemplate.Template?,
        headerPrinted: inout Bool
    ) throws {
        let object = annotate(parseObject(line))
        guard let template else {
            print(pretty(object))
            return
        }
        if template.table {
            let split: (String) -> [String] = {
                $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
            let cells = split(try FormatTemplate.render(template, object: object))
            if headerPrinted {
                print(cells.joined(separator: "   "))
            } else {
                Table.print(headers: split(template.header), rows: [cells])
                headerPrinted = true
            }
            return
        }
        print(try FormatTemplate.render(template, object: object))
    }

    /// Docker `--format` still exposes the deprecated `Status` / `ID` / `From` aliases.
    private static func annotate(_ object: [String: Any]) -> [String: Any] {
        var event = object
        let actor = dict(event["Actor"])
        let attributes = dict(actor["Attributes"])
        let id = (actor["ID"] as? String) ?? ""
        let action = (event["Action"] as? String) ?? ""
        if event["ID"] == nil { event["ID"] = id }
        if event["Status"] == nil { event["Status"] = action }
        if event["From"] == nil { event["From"] = attributes["image"] ?? attributes["name"] ?? "" }
        if event["Scope"] == nil { event["Scope"] = "local" }
        return event
    }

    private static func pretty(_ object: [String: Any]) -> String {
        let actor = dict(object["Actor"])
        let id = (actor["ID"] as? String) ?? (object["ID"] as? String) ?? ""
        let type = (object["Type"] as? String) ?? ""
        let action = (object["Action"] as? String) ?? ""
        let time = int64(object["time"])
        let timeNano = int64(object["timeNano"])
        var line = "\(Format.rfc3339Nano(time: time, timeNano: timeNano)) \(type) \(action) \(id)"
        let attributes = dict(actor["Attributes"])
        if !attributes.isEmpty {
            let parts = attributes.keys.sorted().map { key in
                "\(key)=\(stringValue(attributes[key]))"
            }
            line += " (\(parts.joined(separator: ", ")))"
        }
        return line
    }

    private static func parseObject(_ line: String) -> [String: Any] {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return [:] }
        return dict(object)
    }

    private static func dict(_ object: Any?) -> [String: Any] {
        if let dict = object as? [String: Any] { return dict }
        guard let dict = object as? NSDictionary else { return [:] }
        var result: [String: Any] = [:]
        result.reserveCapacity(dict.count)
        for (key, value) in dict {
            if let key = key as? String {
                result[key] = value
            }
        }
        return result
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? Double { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        return 0
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String { return text }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        return "\(value)"
    }
}

struct SystemDf: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "df", abstract: "Show docker disk usage.")

    @Flag(name: [.customShort("v"), .long], help: "Show detailed information on space usage.")
    var verbose = false

    @Option(help: "Format output using a custom template (table, {{.Field}}, json).")
    var format: String?

    func run() throws {
        let usage = try DaemonAPI.decode(DiskUsage.self, from: DaemonAPI.get("/system/df"))
        if verbose {
            Self.printVerbose(usage)
            return
        }
        let rows = Self.summaryRows(usage)
        if let format, !FormatTemplate.isBareTable(format) {
            try FormatTemplate.print(format: format, objects: rows.map(\.fields))
            return
        }
        Table.print(
            headers: ["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"],
            rows: rows.map { [$0.type, $0.total, $0.active, $0.size, $0.reclaimable] }
        )
    }

    private static func summaryRows(_ usage: DiskUsage) -> [SummaryRow] {
        let images = usage.Images ?? []
        let containers = usage.Containers ?? []
        let volumes = usage.Volumes ?? []
        let imageTotal = usage.LayersSize ?? images.reduce(0) { $0 + $1.Size }
        let unusedImages = images.filter { !imageInUse($0, containers: containers) }
        let unusedImageSize = min(imageTotal, unusedImages.reduce(0) { $0 + $1.Size })
        let volumeTotal = volumes.reduce(Int64(0)) { $0 + ($1.UsageData?.Size ?? 0) }
        let unusedVolumes = volumes.filter { ($0.UsageData?.RefCount ?? 0) <= 0 }
        let unusedVolumeSize = unusedVolumes.reduce(Int64(0)) { $0 + ($1.UsageData?.Size ?? 0) }
        return [
            SummaryRow(
                type: "Images",
                total: images.count,
                active: images.count - unusedImages.count,
                size: imageTotal,
                reclaimable: unusedImageSize
            ),
            SummaryRow(
                type: "Containers",
                total: containers.count,
                active: containers.filter { $0.State == "running" }.count,
                size: 0,
                reclaimable: 0
            ),
            SummaryRow(
                type: "Local Volumes",
                total: volumes.count,
                active: volumes.filter { ($0.UsageData?.RefCount ?? 0) > 0 }.count,
                size: volumeTotal,
                reclaimable: unusedVolumeSize
            ),
            SummaryRow(
                type: "Build Cache",
                total: 0,
                active: 0,
                size: 0,
                reclaimable: 0
            ),
        ]
    }

    private static func printVerbose(_ usage: DiskUsage) {
        let images = usage.Images ?? []
        let containers = usage.Containers ?? []
        let volumes = usage.Volumes ?? []

        print("Images space usage:\n")
        Table.print(
            headers: ["REPOSITORY", "TAG", "IMAGE ID", "CREATED", "SIZE", "SHARED SIZE", "UNIQUE SIZE", "CONTAINERS"],
            rows: images.map { image in
                let (repo, tag) = splitRepoTag(image.RepoTags?.first)
                let shared = max(0, image.SharedSize ?? 0)
                let unique = max(0, image.Size - shared)
                return [
                    ImageReferenceDisplay.shortened(repo),
                    tag,
                    Format.shortID(image.Id),
                    Format.timeAgo(image.Created ?? 0),
                    Format.size(image.Size),
                    Format.size(shared),
                    Format.size(unique),
                    String(containers.filter { containerUses($0, image: image) }.count),
                ]
            }
        )

        print("\nContainers space usage:\n")
        Table.print(
            headers: ["CONTAINER ID", "IMAGE", "COMMAND", "LOCAL VOLUMES", "SIZE", "CREATED", "STATUS", "NAMES"],
            rows: containers.map { container in
                [
                    Format.shortID(container.Id),
                    ImageReferenceDisplay.shortened(container.Image),
                    Format.ellipsis(container.Command ?? ""),
                    String(container.Mounts?.count ?? 0),
                    Format.size(0),
                    Format.timeAgo(container.Created ?? 0),
                    container.Status,
                    (container.Names ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }.joined(separator: ","),
                ]
            }
        )

        print("\nLocal Volumes space usage:\n")
        Table.print(
            headers: ["VOLUME NAME", "LINKS", "SIZE"],
            rows: volumes.map {
                [$0.Name, String($0.UsageData?.RefCount ?? 0), Format.size($0.UsageData?.Size ?? 0)]
            }
        )

        print("\nBuild cache usage: \(Format.size(0))\n")
        Table.print(
            headers: ["CACHE ID", "CACHE TYPE", "SIZE", "CREATED", "LAST USED", "USAGE", "SHARED"],
            rows: []
        )
    }

    private static func imageInUse(_ image: DiskUsage.Image, containers: [DiskUsage.Container]) -> Bool {
        containers.contains { containerUses($0, image: image) }
    }

    private static func containerUses(_ container: DiskUsage.Container, image: DiskUsage.Image) -> Bool {
        let imageID = container.ImageID ?? ""
        if !imageID.isEmpty, imageID == image.Id || image.Id.hasSuffix(imageID) || imageID.hasSuffix(image.Id) {
            return true
        }
        return image.RepoTags?.contains(container.Image) == true
    }

    private static func splitRepoTag(_ value: String?) -> (String, String) {
        guard let value, !value.isEmpty else { return ("<none>", "<none>") }
        if let colon = value.lastIndex(of: ":"), !value[value.index(after: colon)...].contains("/") {
            return (String(value[..<colon]), String(value[value.index(after: colon)...]))
        }
        return (value, "<none>")
    }

    private static func reclaimableText(_ unused: Int64, total: Int64) -> String {
        let human = Format.size(unused)
        guard total > 0 else { return human }
        return "\(human) (\(unused * 100 / total)%)"
    }

    fileprivate struct SummaryRow {
        var type: String
        var total: String
        var active: String
        var size: String
        var reclaimable: String
        var fields: [String: Any]

        init(type: String, total: Int, active: Int, size: Int64, reclaimable: Int64) {
            self.type = type
            self.total = String(total)
            self.active = String(active)
            self.size = Format.size(size)
            self.reclaimable = SystemDf.reclaimableText(reclaimable, total: size)
            self.fields = [
                "Type": type,
                "TotalCount": self.total,
                "Active": self.active,
                "Size": self.size,
                "Reclaimable": self.reclaimable,
            ]
        }
    }
}

struct SystemPrune: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Remove unused data."
    )

    @Flag(name: [.customShort("a"), .long], help: "Remove all unused images, not just dangling ones.")
    var all = false

    @Flag(name: [.customShort("f"), .long], help: "Do not prompt for confirmation.")
    var force = false

    @Option(help: "Provide filter values (e.g. 'until=24h').")
    var filter: [String] = []

    @Flag(help: "Prune anonymous unused volumes.")
    var volumes = false

    /// Never broaden a system-wide filter when an individual resource cannot apply it.
    static func includesBuildCache(filters: [String], volumes: Bool) throws -> Bool {
        var cache = true
        for filter in filters {
            switch filter.prefix(while: { $0 != "=" }) {
            case "until":
                guard !volumes else { throw CLIError.io("volume prune does not support the until filter") }
            case "label", "label!":
                cache = false
            default:
                throw CLIError.io("unsupported system prune filter: \(filter)")
            }
        }
        return cache
    }

    func run() throws {
        let includeCache = try Self.includesBuildCache(filters: filter, volumes: volumes)
        var warning = "This will remove:\n"
        warning += "  - all stopped containers\n"
        warning += "  - all networks not used by at least one container\n"
        warning += all
            ? "  - all images without at least one container associated to them\n"
            : "  - all dangling images\n"
        if volumes {
            warning += "  - all anonymous volumes not used by at least one container\n"
        }
        warning += includeCache ? "  - all unused build cache" : "  (build cache is kept: label filters do not apply)"
        guard Prompt.confirm(warning, force: force) else { return }

        var reclaimed: Int64 = 0
        reclaimed += try pruneContainers()
        try pruneNetworks()
        reclaimed += try pruneImages()
        if volumes {
            reclaimed += try pruneVolumes()
        }
        if includeCache { reclaimed += try pruneBuildCache() }
        print("Total reclaimed space: \(Format.size(reclaimed))")
    }

    private func pruneContainers() throws -> Int64 {
        let result = try DaemonAPI.decode(
            ContainerPruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath("/containers/prune", filters: filter))
        )
        if let ids = result.containersDeleted, !ids.isEmpty {
            print("Deleted Containers:")
            for id in ids { print(id) }
        }
        return result.spaceReclaimed ?? 0
    }

    private func pruneNetworks() throws {
        let result = try DaemonAPI.decode(
            NetworkPruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath("/networks/prune", filters: filter))
        )
        if let names = result.networksDeleted, !names.isEmpty {
            print("Deleted Networks:")
            for name in names { print(name) }
        }
    }

    private func pruneImages() throws -> Int64 {
        let filters = all ? filter + ["dangling=false"] : filter
        let result = try DaemonAPI.decode(
            ImagePruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath("/images/prune", filters: filters), timeoutSeconds: 120)
        )
        if let items = result.imagesDeleted, !items.isEmpty {
            print("Deleted Images:")
            for item in items {
                if let untagged = item.untagged { print("untagged: \(untagged)") }
                if let deleted = item.deleted { print("deleted: \(deleted)") }
            }
        }
        return result.spaceReclaimed ?? 0
    }

    private func pruneVolumes() throws -> Int64 {
        let result = try DaemonAPI.decode(
            VolumePruneResponse.self,
            from: DaemonAPI.post(try DaemonAPI.filteredPath(DaemonAPI.volumePrunePath, filters: filter), timeoutSeconds: 120)
        )
        if let names = result.volumesDeleted, !names.isEmpty {
            print("Deleted Volumes:")
            for name in names { print(name) }
        }
        return result.spaceReclaimed ?? 0
    }

    private func pruneBuildCache() throws -> Int64 {
        var extra: [String] = []
        if all { extra.append("all=1") }
        let result = try DaemonAPI.decode(
            BuildPruneResponse.self,
            from: DaemonAPI.post(
                try DaemonAPI.filteredPath("/build/prune", filters: filter, extra: extra),
                timeoutSeconds: 300
            )
        )
        if let ids = result.cachesDeleted, !ids.isEmpty {
            print("Deleted build cache objects:")
            for id in ids { print(id) }
        }
        return result.spaceReclaimed ?? 0
    }
}

struct SystemDialStdio: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dial-stdio",
        abstract: "Proxy the daemon UNIX socket over stdin and stdout."
    )

    func run() throws {
        let socketPath = try DaemonAPI.socket()
        let fd = try Self.connect(socketPath)
        defer { Darwin.close(fd) }
        let input = FileHandle.standardInput.fileDescriptor
        let output = FileHandle.standardOutput.fileDescriptor
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            Self.copy(from: input, to: fd)
            _ = shutdown(fd, SHUT_WR)
        }
        Self.copy(from: fd, to: output)
        group.wait()
    }

    private static func connect(_ socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError.http("failed to create UNIX socket: \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard socketPath.utf8.count <= pathLimit else {
            Darwin.close(fd)
            throw CLIError.http("socket path exceeds UNIX address limit: \(socketPath)")
        }
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyBytes(from: UnsafeRawBufferPointer(start: src, count: socketPath.utf8.count + 1))
            }
        }
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw CLIError.http("cannot connect to \(socketPath): \(message)")
        }
        return fd
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            var offset = 0
            while offset < count {
                let wrote = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(destination, base + offset, count - offset)
                }
                if wrote < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if wrote == 0 { return }
                offset += wrote
            }
        }
    }
}

struct SystemGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "Manage Macker.",
        subcommands: [SystemDf.self, Info.self, Events.self, SystemPrune.self, SystemDialStdio.self]
    )
}

private struct VersionInfo: Decodable {
    var Version: String
    var ApiVersion: String
    var Os: String
    var Arch: String
}

private struct DiskUsage: Decodable {
    var LayersSize: Int64?
    var Images: [Image]?
    var Containers: [Container]?
    var Volumes: [Volume]?

    struct Image: Decodable {
        var Id: String
        var RepoTags: [String]?
        var Created: Int64?
        var Size: Int64
        var SharedSize: Int64?
    }

    struct Container: Decodable {
        var Id: String
        var Image: String
        var ImageID: String?
        var Command: String?
        var Created: Int64?
        var State: String
        var Status: String
        var Names: [String]?
        var Mounts: [Mount]?
    }

    struct Mount: Decodable {}

    struct Volume: Decodable {
        var Name: String
        var UsageData: Usage?

        struct Usage: Decodable {
            var Size: Int64
            var RefCount: Int64
        }
    }
}
