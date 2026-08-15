import Foundation

public struct EngineVolume: Sendable, Codable {
    public var name: String
    public var driver: String
    public var createdAt: Date
    public var labels: [String: String]
    public var options: [String: String]
    public var scope: String
    public var anonymous: Bool
}

public struct EngineVolumeInfo: Sendable {
    public let volume: EngineVolume
    public let mountpoint: String
    public let size: Int64
    public let refCount: Int
}

public struct EngineVolumeCreateSpec: Sendable {
    public var name: String?
    public var driver: String
    public var labels: [String: String]
    public var options: [String: String]
    public var anonymous: Bool

    public init(
        name: String? = nil,
        driver: String = "local",
        labels: [String: String] = [:],
        options: [String: String] = [:],
        anonymous: Bool = false
    ) {
        self.name = name
        self.driver = driver
        self.labels = labels
        self.options = options
        self.anonymous = anonymous
    }
}

public struct EngineVolumeRequest: Sendable {
    public var type: String
    public var source: String
    public var destination: String
    public var readOnly: Bool
    public var anonymous: Bool

    public init(
        type: String,
        source: String,
        destination: String,
        readOnly: Bool = false,
        anonymous: Bool = false
    ) {
        self.type = type
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
        self.anonymous = anonymous
    }
}

public struct EngineMount: Sendable {
    public var type: String
    public var name: String
    public var source: String
    public var destination: String
    public var rw: Bool
    public var anonymous: Bool

    public init(
        type: String,
        name: String,
        source: String,
        destination: String,
        rw: Bool,
        anonymous: Bool = false
    ) {
        self.type = type
        self.name = name
        self.source = source
        self.destination = destination
        self.rw = rw
        self.anonymous = anonymous
    }
}
