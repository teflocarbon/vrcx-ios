import Foundation

/// Sample data and a starting screen for screenshots: launch with
/// `-demo -demoScreen <name>` (see tools/screenshots.sh). Never touches
/// the Keychain, the network or a real account, so screenshots never show
/// real people.
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demo")

    enum Screen: String, CaseIterable {
        case friends, inbox, feed, you
    }

    static var screen: Screen {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demoScreen"), index + 1 < arguments.count else {
            return .friends
        }
        return Screen(rawValue: arguments[index + 1]) ?? .friends
    }
}
