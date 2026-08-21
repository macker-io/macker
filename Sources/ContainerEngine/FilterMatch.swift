import Foundation

enum FilterMatch {
    static func labels(_ labels: [String: String], specs: [String]) -> Bool {
        specs.allSatisfy { spec in
            if let eq = spec.firstIndex(of: "=") {
                let key = String(spec[..<eq])
                let value = String(spec[spec.index(after: eq)...])
                return labels[key] == value
            }
            return labels[spec] != nil
        }
    }

    static func isTrue(_ values: [String]?) -> Bool {
        values?.contains(where: { $0 == "true" || $0 == "1" }) == true
    }

    static func isFalse(_ values: [String]?) -> Bool {
        values?.contains(where: { $0 == "false" || $0 == "0" }) == true
    }
}
