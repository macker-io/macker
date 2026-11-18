import Foundation

public enum FilterMatch {
    /// `key` or `key=value` specs, all of which must match.
    public static func labels(_ labels: [String: String], specs: [String]) -> Bool {
        specs.allSatisfy { spec in
            if let eq = spec.firstIndex(of: "=") {
                let key = String(spec[..<eq])
                let value = String(spec[spec.index(after: eq)...])
                return labels[key] == value
            }
            return labels[spec] != nil
        }
    }

    /// Docker's `reference` filter (`reference.FamiliarMatch`): a `path.Match` glob against the
    /// familiar `name:tag`, then against the familiar name alone. `*` does not cross `/`.
    public static func reference(_ pattern: String, references: [String]) -> Bool {
        references.contains { reference in
            for alias in EngineManager.aliases(for: reference) {
                if glob(pattern, alias) { return true }
                let name = repositoryName(alias)
                if name != alias, glob(pattern, name) { return true }
            }
            return false
        }
    }

    /// `name:tag` / `name@digest` → `name` (a registry port's `:` is not a tag separator).
    static func repositoryName(_ reference: String) -> String {
        if let at = reference.firstIndex(of: "@") {
            return String(reference[..<at])
        }
        let lastSlash = reference.lastIndex(of: "/") ?? reference.startIndex
        if let colon = reference[lastSlash...].lastIndex(of: ":") {
            return String(reference[..<colon])
        }
        return reference
    }

    static func glob(_ pattern: String, _ value: String) -> Bool {
        fnmatch(pattern, value, FNM_PATHNAME) == 0
    }

    static func isTrue(_ values: [String]?) -> Bool {
        values?.contains(where: { $0 == "true" || $0 == "1" }) == true
    }

    static func isFalse(_ values: [String]?) -> Bool {
        values?.contains(where: { $0 == "false" || $0 == "0" }) == true
    }
}
