import Foundation

/// RepoRadar's settings, kept in UserDefaults. Tests pass their own defaults.
@MainActor
final class Preferences: ObservableObject {
    enum ClickAction: String, CaseIterable, Sendable {
        case finder, terminal, editor
    }

    /// How often to fetch in the background, in seconds; 0 is never
    static let fetchIntervals: [TimeInterval] = [0, 15 * 60, 60 * 60]

    let defaults: UserDefaults

    @Published var folders: [String] { didSet { defaults.set(folders, forKey: Keys.folders) } }
    @Published var ignored: [String] { didSet { defaults.set(ignored, forKey: Keys.ignored) } }
    /// Repo path → when the snooze ends
    @Published var snoozed: [String: Date] { didSet { defaults.set(snoozed, forKey: Keys.snoozed) } }
    @Published var clickAction: ClickAction { didSet { defaults.set(clickAction.rawValue, forKey: Keys.clickAction) } }
    @Published var terminalApp: String { didSet { defaults.set(terminalApp, forKey: Keys.terminalApp) } }
    @Published var editorApp: String? { didSet { defaults.set(editorApp, forKey: Keys.editorApp) } }
    @Published var fetchInterval: TimeInterval { didSet { defaults.set(fetchInterval, forKey: Keys.fetchInterval) } }
    @Published var lastFetched: Date? { didSet { defaults.set(lastFetched, forKey: Keys.lastFetched) } }
    @Published var reminderEnabled: Bool { didSet { defaults.set(reminderEnabled, forKey: Keys.reminderEnabled) } }
    /// Minutes after midnight
    @Published var reminderMinutes: Int { didSet { defaults.set(reminderMinutes, forKey: Keys.reminderMinutes) } }
    /// The day the reminder last went off, as yyyy-MM-dd
    @Published var lastReminderDay: String? { didSet { defaults.set(lastReminderDay, forKey: Keys.lastReminderDay) } }

    enum Keys {
        static let folders = "watchedFolders"
        static let ignored = "ignoredRepos"
        static let snoozed = "snoozedRepos"
        static let clickAction = "clickAction"
        static let terminalApp = "terminalApp"
        static let editorApp = "editorApp"
        static let fetchInterval = "fetchInterval"
        static let lastFetched = "lastFetched"
        static let reminderEnabled = "reminderEnabled"
        static let reminderMinutes = "reminderMinutes"
        static let lastReminderDay = "lastReminderDay"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders = defaults.stringArray(forKey: Keys.folders) ?? []
        ignored = defaults.stringArray(forKey: Keys.ignored) ?? []
        snoozed = (defaults.dictionary(forKey: Keys.snoozed) as? [String: Date]) ?? [:]
        clickAction = defaults.string(forKey: Keys.clickAction).flatMap(ClickAction.init) ?? .finder
        terminalApp = defaults.string(forKey: Keys.terminalApp) ?? AppChoice.defaultTerminal
        editorApp = defaults.string(forKey: Keys.editorApp) ?? AppChoice.installedEditors.first?.bundleID
        fetchInterval = defaults.object(forKey: Keys.fetchInterval) as? TimeInterval ?? 0
        lastFetched = defaults.object(forKey: Keys.lastFetched) as? Date
        reminderEnabled = defaults.bool(forKey: Keys.reminderEnabled)
        reminderMinutes = defaults.object(forKey: Keys.reminderMinutes) as? Int ?? (17 * 60 + 30)
        lastReminderDay = defaults.string(forKey: Keys.lastReminderDay)
    }

    func addFolder(_ path: String) {
        let path = (path as NSString).standardizingPath
        // A folder already inside a watched one adds nothing
        guard !folders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        // A folder that contains watched ones replaces them
        folders.removeAll { $0.hasPrefix(path + "/") }
        folders.append(path)
        folders.sort()
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
    }

    func isSnoozed(_ path: String, now: Date = Date()) -> Bool {
        snoozed[path].map { $0 > now } ?? false
    }

    func snooze(_ path: String, for interval: TimeInterval, now: Date = Date()) {
        snoozed[path] = now.addingTimeInterval(interval)
    }

    func wake(_ path: String) {
        snoozed[path] = nil
    }

    /// Forget snoozes that have ended
    func clearEndedSnoozes(now: Date = Date()) {
        let ended = snoozed.filter { $0.value <= now }.map(\.key)
        guard !ended.isEmpty else { return }
        ended.forEach { snoozed[$0] = nil }
    }

    func ignore(_ path: String) {
        guard !ignored.contains(path) else { return }
        ignored.append(path)
        snoozed[path] = nil
    }

    func unignore(_ path: String) {
        ignored.removeAll { $0 == path }
    }
}
