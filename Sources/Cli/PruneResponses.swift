import Foundation

struct ContainerPruneResponse: Decodable {
    var containersDeleted: [String]?
    var spaceReclaimed: Int64?

    enum CodingKeys: String, CodingKey {
        case containersDeleted = "ContainersDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }
}

struct NetworkPruneResponse: Decodable {
    var networksDeleted: [String]?

    enum CodingKeys: String, CodingKey {
        case networksDeleted = "NetworksDeleted"
    }
}

struct VolumePruneResponse: Decodable {
    var volumesDeleted: [String]?
    var spaceReclaimed: Int64?

    enum CodingKeys: String, CodingKey {
        case volumesDeleted = "VolumesDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }
}

struct BuildPruneResponse: Decodable {
    var cachesDeleted: [String]?
    var spaceReclaimed: Int64?

    enum CodingKeys: String, CodingKey {
        case cachesDeleted = "CachesDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }
}

struct ImageDeleteItem: Decodable {
    var untagged: String?
    var deleted: String?

    enum CodingKeys: String, CodingKey {
        case untagged = "Untagged"
        case deleted = "Deleted"
    }
}

struct ImagePruneResponse: Decodable {
    var imagesDeleted: [ImageDeleteItem]?
    var spaceReclaimed: Int64?

    enum CodingKeys: String, CodingKey {
        case imagesDeleted = "ImagesDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }
}
