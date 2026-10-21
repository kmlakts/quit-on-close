import Foundation
import Observation

enum QuitMode: String {
    /// Quit every app except the listed ones.
    case allExcept
    /// Quit only the listed apps.
    case onlyListed
}

/// User preferences, persisted in UserDefaults.
@MainActor @Observable
final class Settings {
    private enum Key {
        static let isEnabled = "isEnabled"
        static let mode = "mode"
        static let apps = "apps"
        static let closeDelay = "closeDelay"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }
    var mode: QuitMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    /// Bundle identifiers of the apps the mode refers to.
    var apps: [String] { didSet { defaults.set(apps, forKey: Key.apps) } }
    /// Seconds to wait after the last window closes before quitting.
    var closeDelay: Int { didSet { defaults.set(closeDelay, forKey: Key.closeDelay) } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: true,
            Key.mode: QuitMode.allExcept.rawValue,
            Key.apps: [String](),
            Key.closeDelay: 2,
            Key.showMenuBarIcon: true,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        mode = QuitMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .allExcept
        apps = defaults.stringArray(forKey: Key.apps) ?? []
        closeDelay = max(1, defaults.integer(forKey: Key.closeDelay))
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
    }

    /// Whether the user's rules allow quitting the app with this bundle identifier.
    func allowsQuitting(_ bundleID: String) -> Bool {
        switch mode {
        case .allExcept: !apps.contains(bundleID)
        case .onlyListed: apps.contains(bundleID)
        }
    }

    func add(_ bundleID: String) {
        if !apps.contains(bundleID) { apps.append(bundleID) }
    }

    func remove(_ bundleID: String) {
        apps.removeAll { $0 == bundleID }
    }
}
