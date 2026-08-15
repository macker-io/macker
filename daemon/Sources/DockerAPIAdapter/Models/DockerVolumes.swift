import ContainerEngine
import Foundation

public struct DockerVolume: Encodable, Sendable {
    public let Name: String
    public let Driver: String
    public let Mountpoint: String
    public let CreatedAt: String
    public let Labels: [String: String]
    public let Scope: String
    public let Options: [String: String]
    public let UsageData: UsageData?

    public struct UsageData: Encodable, Sendable {
        public let Size: Int64
        public let RefCount: Int64
    }

    public init(_ info: EngineVolumeInfo, includeUsage: Bool = true) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.Name = info.volume.name
        self.Driver = info.volume.driver
        self.Mountpoint = info.mountpoint
        self.CreatedAt = iso.string(from: info.volume.createdAt)
        self.Labels = info.volume.labels
        self.Scope = info.volume.scope
        self.Options = info.volume.options
        self.UsageData = includeUsage
            ? .init(Size: info.size, RefCount: Int64(info.refCount))
            : nil
    }
}

public struct DockerVolumeListResponse: Encodable, Sendable {
    public let Volumes: [DockerVolume]
    public let Warnings: [String]
}

public struct DockerCreateVolumeRequest: Decodable, Sendable {
    public let Name: String?
    public let Driver: String?
    public let DriverOpts: [String: String]?
    public let Labels: [String: String]?

    public init(
        Name: String? = nil,
        Driver: String? = nil,
        DriverOpts: [String: String]? = nil,
        Labels: [String: String]? = nil
    ) {
        self.Name = Name
        self.Driver = Driver
        self.DriverOpts = DriverOpts
        self.Labels = Labels
    }
}

public struct DockerVolumePruneResponse: Encodable, Sendable {
    public let VolumesDeleted: [String]
    public let SpaceReclaimed: Int64
}
