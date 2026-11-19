/// Presentation only: keep canonical references for API requests and comparisons.
public enum ImageReferenceDisplay {
    public static func shortened(_ reference: String) -> String {
        let prefix = "docker.io/library/"
        guard reference.hasPrefix(prefix) else { return reference }
        return String(reference.dropFirst(prefix.count))
    }
}
