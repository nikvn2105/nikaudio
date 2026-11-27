import Foundation

enum ScreenProbe {
    static let appGroup = "group.com.nikvn2105.nikaudio"
    static let extensionBundle = "com.nikvn2105.nikaudio.screen-broadcast"
    static let stateKey = "screenProbeState"

    enum State: String {
        case waiting, started, video, stopped
    }

    static var storage: UserDefaults? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil else {
            return nil
        }
        return UserDefaults(suiteName: appGroup)
    }
}
