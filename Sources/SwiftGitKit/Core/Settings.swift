import Foundation

/// How Pull integrates the remote branch.
enum PullMode: String, CaseIterable {
    case gitConfig, merge, rebase, fastForwardOnly

    var title: String {
        switch self {
        case .gitConfig: return "As configured in git (pull.rebase)"
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .fastForwardOnly: return "Fast-forward only"
        }
    }

    var arguments: [String] {
        switch self {
        case .gitConfig: return []
        case .merge: return ["--no-rebase"]
        case .rebase: return ["--rebase"]
        case .fastForwardOnly: return ["--ff-only"]
        }
    }
}

/// App preferences (UserDefaults). Read on use, so changes apply immediately.
enum Settings {
    static let changed = Notification.Name("SwiftGitSettingsChanged")

    enum Key {
        static let fetchOnFocus = "fetch.onFocus"
        static let pullMode = "pull.mode"
        static let autostash = "pull.autostash"
        static let claudeEnabled = "claude.enabled"
        static let claudeModel = "claude.model"
        static let topoOrder = "history.topoOrder"   // = Repository.topoOrderKey
    }

    /// Minimum time between two automatic fetches of the same repository.
    static let focusFetchInterval: TimeInterval = 30

    static var defaults: UserDefaults = .standard

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.fetchOnFocus: true,
            Key.pullMode: PullMode.gitConfig.rawValue,
            Key.autostash: false,
            Key.claudeEnabled: true,
            Key.claudeModel: "haiku",
        ])
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    static var fetchOnFocus: Bool {
        get { bool(Key.fetchOnFocus, true) }
        set { defaults.set(newValue, forKey: Key.fetchOnFocus); post() }
    }

    static var pullMode: PullMode {
        get { defaults.string(forKey: Key.pullMode).flatMap(PullMode.init(rawValue:)) ?? .gitConfig }
        set { defaults.set(newValue.rawValue, forKey: Key.pullMode); post() }
    }

    /// Stash local changes before pulling (and re-apply them) without asking.
    static var autostash: Bool {
        get { bool(Key.autostash, false) }
        set { defaults.set(newValue, forKey: Key.autostash); post() }
    }

    static var claudeEnabled: Bool {
        get { bool(Key.claudeEnabled, true) }
        set { defaults.set(newValue, forKey: Key.claudeEnabled); post() }
    }

    static var claudeModel: String {
        get {
            let m = defaults.string(forKey: Key.claudeModel)?.trimmingCharacters(in: .whitespaces) ?? ""
            return m.isEmpty ? "haiku" : m
        }
        set { defaults.set(newValue, forKey: Key.claudeModel); post() }
    }

    static var topoOrder: Bool {
        get { defaults.bool(forKey: Key.topoOrder) }
        set { defaults.set(newValue, forKey: Key.topoOrder); post() }
    }

    private static func post() { NotificationCenter.default.post(name: changed, object: nil) }
}
