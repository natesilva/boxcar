import DockerRuntime
import Foundation

enum DockerCommandSource: String {
    case automatic
    case custom
}

enum DockerSettings {
    static let sourceKey = "dockerCommandSource"
    static let customPathKey = "customDockerPath"

    static func selection(defaults: UserDefaults = .standard) -> DockerCLISelection {
        let source = defaults.string(forKey: sourceKey).flatMap(DockerCommandSource.init) ?? .automatic
        switch source {
        case .automatic: return .automatic
        case .custom: return .custom(path: defaults.string(forKey: customPathKey) ?? "")
        }
    }
}
