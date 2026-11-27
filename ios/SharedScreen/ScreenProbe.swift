import Foundation

enum ScreenProbe {
    static let appGroup = "group.com.nikvn2105.nikaudio"
    static let extensionBundle = "com.nikvn2105.nikaudio.screen-broadcast"
    static let stateKey = "screenProbeState"
    static let configKey = "screenDestination"

    enum State: String {
        case waiting, started, video, reconnecting, stopped, failed
    }

    struct Destination: Codable, Sendable {
        let address: String
        let service: String?
        let key: Data
    }

    static var storage: UserDefaults? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil else {
            return nil
        }
        return UserDefaults(suiteName: appGroup)
    }
}
