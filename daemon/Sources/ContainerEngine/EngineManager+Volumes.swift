import Foundation

extension EngineManager {
    public func listVolumes(filters: [String: [String]] = [:]) -> [EngineVolumeInfo] {
        var items = volumes.values.map(volumeInfo)
        if let names = filters["name"], !names.isEmpty {
            items = items.filter { item in names.contains { item.volume.name.contains($0) } }
        }
        if let drivers = filters["driver"], !drivers.isEmpty {
            items = items.filter { drivers.contains($0.volume.driver) }
        }
        if let labels = filters["label"], !labels.isEmpty {
            items = items.filter { FilterMatch.labels($0.volume.labels, specs: labels) }
        }
        if let excluded = filters["label!"], !excluded.isEmpty {
            items = items.filter { !FilterMatch.labels($0.volume.labels, specs: excluded) }
        }
        if let dangling = filters["dangling"], !dangling.isEmpty {
            let wantUnused = FilterMatch.isTrue(dangling)
            items = items.filter { wantUnused ? $0.refCount == 0 : $0.refCount > 0 }
        }
        return items.sorted { $0.volume.name < $1.volume.name }
    }

    public func inspectVolume(_ name: String) throws -> EngineVolumeInfo {
        volumeInfo(try resolveVolume(name))
    }

    public func createVolume(_ spec: EngineVolumeCreateSpec) async throws -> EngineVolumeInfo {
        let driver = spec.driver.isEmpty ? "local" : spec.driver
        guard driver == "local" else {
            throw EngineError.invalidArgument("volume driver \"\(driver)\" is not supported")
        }

        let raw = spec.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name: String
        if raw.isEmpty {
            name = spec.anonymous ? Self.makeContainerID() : "macker-\(String(Self.makeContainerID().prefix(12)))"
        } else {
            guard Self.isValidVolumeName(raw) else {
                throw EngineError.invalidArgument("Invalid volume name: \(raw)")
            }
            name = raw
        }

        if volumes[name] != nil {
            throw EngineError.conflict("create \(name): conflict. The volume already exists")
        }

        let volume = EngineVolume(
            name: name,
            driver: driver,
            createdAt: Date(),
            labels: spec.labels,
            options: spec.options,
            scope: "local",
            anonymous: spec.anonymous
        )
        try persistVolume(volume)
        volumes[name] = volume
        await publish(
            EngineEvent(
                type: "volume",
                action: "create",
                actorID: name,
                attributes: ["driver": driver]
            )
        )
        return volumeInfo(volume)
    }

    public func deleteVolume(_ name: String, force: Bool) async throws {
        let volume = try resolveVolume(name)
        let refs = volumeRefCount(volume.name)
        if refs > 0, !force {
            throw EngineError.conflict("remove \(volume.name): volume is in use")
        }
        try removeVolumeFiles(volume.name)
        volumes[volume.name] = nil
        await publish(
            EngineEvent(
                type: "volume",
                action: "destroy",
                actorID: volume.name,
                attributes: ["driver": volume.driver]
            )
        )
    }

    public func pruneVolumes(filters: [String: [String]] = [:]) async throws -> (deleted: [String], spaceReclaimed: Int64) {
        var filters = filters
        let all = FilterMatch.isTrue(filters.removeValue(forKey: "all"))
        var unused = listVolumes(filters: filters).filter { $0.refCount == 0 }
        if !all {
            unused = unused.filter(\.volume.anonymous)
        }
        var deleted: [String] = []
        var reclaimed: Int64 = 0
        for item in unused {
            reclaimed += item.size
            try await deleteVolume(item.volume.name, force: true)
            deleted.append(item.volume.name)
        }
        return (deleted, reclaimed)
    }

    func resolveMounts(_ requests: [EngineVolumeRequest], tmpfsRoot: URL? = nil) async throws -> [EngineMount] {
        var mounts: [EngineMount] = []
        for request in requests {
            if request.type == "tmpfs" {
                let root = tmpfsRoot ?? FileManager.default.temporaryDirectory
                let leaf = request.destination.replacingOccurrences(of: "/", with: "_")
                let dir = root.appendingPathComponent(leaf.isEmpty ? "tmpfs" : leaf, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                mounts.append(
                    EngineMount(
                        type: "tmpfs",
                        name: "",
                        source: dir.path,
                        destination: request.destination,
                        rw: true
                    )
                )
                continue
            }
            if request.type == "bind" {
                mounts.append(
                    EngineMount(
                        type: "bind",
                        name: "",
                        source: request.source,
                        destination: request.destination,
                        rw: !request.readOnly
                    )
                )
                continue
            }

            let name: String
            let anonymous: Bool
            if request.anonymous || request.source.isEmpty {
                let created = try await createVolume(EngineVolumeCreateSpec(anonymous: true))
                name = created.volume.name
                anonymous = true
            } else if volumes[request.source] == nil {
                let created = try await createVolume(EngineVolumeCreateSpec(name: request.source))
                name = created.volume.name
                anonymous = false
            } else {
                name = request.source
                anonymous = volumes[name]?.anonymous ?? false
            }

            let volume = try resolveVolume(name)
            mounts.append(
                EngineMount(
                    type: "volume",
                    name: name,
                    source: mountpoint(for: volume.name),
                    destination: request.destination,
                    rw: !request.readOnly,
                    anonymous: anonymous
                )
            )
        }
        return mounts
    }

    func volumesFrom(_ specs: [String]) throws -> [EngineVolumeRequest] {
        var requests: [EngineVolumeRequest] = []
        for spec in specs {
            let parsed = EngineVolumeSpec.parseVolumesFrom(spec)
            let source = try resolveContainer(parsed.name)
            for mount in source.mounts {
                var readOnly = !mount.rw
                if let override = parsed.readOnly {
                    readOnly = override
                }
                requests.append(
                    EngineVolumeRequest(
                        type: mount.type == "bind" ? "bind" : (mount.type == "tmpfs" ? "tmpfs" : "volume"),
                        source: mount.type == "volume" ? mount.name : mount.source,
                        destination: mount.destination,
                        readOnly: readOnly,
                        anonymous: false
                    )
                )
            }
        }
        return requests
    }

    func resolveVolume(_ name: String) throws -> EngineVolume {
        if let volume = volumes[name] {
            return volume
        }
        throw EngineError.volumeNotFound("get \(name): no such volume")
    }

    static func loadVolumes(from root: URL) -> [String: EngineVolume] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var loaded: [String: EngineVolume] = [:]
        for dir in dirs {
            let config = dir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: config),
                let volume = try? decoder.decode(EngineVolume.self, from: data)
            else {
                continue
            }
            loaded[volume.name] = volume
        }
        return loaded
    }

    static func isValidVolumeName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    private func volumeInfo(_ volume: EngineVolume) -> EngineVolumeInfo {
        let path = mountpoint(for: volume.name)
        return EngineVolumeInfo(
            volume: volume,
            mountpoint: path,
            size: Self.directorySize(URL(fileURLWithPath: path)),
            refCount: volumeRefCount(volume.name)
        )
    }

    private func volumeRefCount(_ name: String) -> Int {
        containers.values.filter { container in
            container.mounts.contains { $0.name == name }
        }.count
    }

    private func mountpoint(for name: String) -> String {
        volumeRoot.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("_data", isDirectory: true)
            .path
    }

    private func persistVolume(_ volume: EngineVolume) throws {
        let dir = volumeRoot.appendingPathComponent(volume.name, isDirectory: true)
        let dataDir = dir.appendingPathComponent("_data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(volume).write(to: dir.appendingPathComponent("config.json"), options: .atomic)
    }

    private func removeVolumeFiles(_ name: String) throws {
        let dir = volumeRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
