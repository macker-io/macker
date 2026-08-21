import ContainerizationError
import ContainerizationOCI
import Foundation

/// Maps registry / OCI client failures onto Docker-shaped ``EngineError`` messages.
enum RegistryErrorMapper {
    enum Operation: Sendable {
        case pull
        case push
    }

    static func map(_ error: Error, reference: String, operation: Operation) -> EngineError {
        if let engine = error as? EngineError {
            return engine
        }

        let description = describe(error)
        let unauthorized = isUnauthorized(status: httpStatus(error), description: description)
        switch operation {
        case .pull:
            if unauthorized {
                let repo = EngineManager.repository(from: reference)
                return .unauthorized(
                    "pull access denied for \(repo), repository does not exist or may require 'docker login'"
                )
            }
            return .pullFailed(description)
        case .push:
            if unauthorized {
                return .unauthorized("denied: requested access to the resource is denied")
            }
            return .pushFailed(description)
        }
    }

    static func login(_ error: Error, host: String, port: Int?) -> EngineError {
        let description = describe(error)
        if isUnauthorized(status: httpStatus(error), description: description) {
            let target = port.map { "\(host):\($0)" } ?? host
            return .unauthorized("Get \"https://\(target)/v2/\": unauthorized: incorrect username or password")
        }
        return .loginFailed(description)
    }

    static func describe(_ error: Error) -> String {
        if let engine = error as? EngineError {
            return engine.localizedDescription
        }
        if let registry = error as? RegistryClient.Error {
            return registry.description
        }
        if let containerization = error as? ContainerizationError {
            if let cause = containerization.cause {
                return describe(cause)
            }
            return containerization.message
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }

    static func isUnauthorized(status: UInt?, description: String) -> Bool {
        if let status, status == 401 || status == 403 {
            return true
        }
        let lower = description.lowercased()
        return lower.contains("unauthorized")
            || lower.contains("access denied")
            || lower.contains("wrong credentials")
            || lower.contains("authentication required")
    }

    private static func httpStatus(_ error: Error) -> UInt? {
        if let registry = error as? RegistryClient.Error {
            if case .invalidStatus(_, let status, _) = registry {
                return status.code
            }
        }
        if let containerization = error as? ContainerizationError, let cause = containerization.cause {
            return httpStatus(cause)
        }
        return nil
    }
}
