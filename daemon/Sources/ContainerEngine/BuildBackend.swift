import Foundation

/// Which engine turns a `POST /build` context tar into an image.
///
/// Today only ``classic`` runs. ``buildkit`` is the next version (docs/buildkit.md):
/// a builder MicroVM with `buildkitd` + `container-builder-shim`, host filesync
/// against `ImageStore`. Swap the body of ``select(dockerfile:)`` when that lands
/// — `EngineBuildSpec` / `EngineBuildEvent` stay the API.
enum BuildBackend: String, Sendable {
    case classic
    case buildkit
}

extension BuildBackend {
    /// Picks an engine from the Dockerfile text. BuildKit-only syntax is rejected
    /// until ``buildkit`` is wired; do not teach the classic parser those features.
    static func select(dockerfile text: String) throws -> BuildBackend {
        if let feature = Dockerfile.buildKitSyntax(in: text) {
            throw EngineError.notImplemented(unsupportedMessage(feature))
        }
        return .classic
    }

    static func rejectBuildKitInstructions(_ file: Dockerfile) throws {
        if let feature = file.buildKitInstruction {
            throw EngineError.notImplemented(unsupportedMessage(feature))
        }
    }

    static func unsupportedMessage(_ feature: String) -> String {
        "\(feature) is a BuildKit feature. macker implements the classic builder only."
    }
}
