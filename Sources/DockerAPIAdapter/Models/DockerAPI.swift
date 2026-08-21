import ContainerEngine
import Foundation

/// Docker Engine API version this daemon advertises.
public enum DockerAPI {
    public static let version = "1.41"
    public static let daemonVersion = ProductVersion.current
    public static let platformName = "macker"
}
