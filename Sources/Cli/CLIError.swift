import Foundation

enum CLIError: Error, LocalizedError {
    case http(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .http(let reason), .io(let reason):
            return reason
        }
    }
}
