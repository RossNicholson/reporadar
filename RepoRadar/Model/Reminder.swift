import Foundation
import UserNotifications

/// The end-of-day reminder: once a day, at the chosen time, a notification
/// if any repos still need you
enum Reminder {
    /// It goes off at the chosen time, or later that evening if the Mac was
    /// asleep then, but not the next morning
    static let window: TimeInterval = 3 * 3600

    static func isDue(now: Date, minutes: Int, lastDay: String?, calendar: Calendar = .current) -> Bool {
        guard lastDay != day(of: now, calendar: calendar),
              let time = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now) else { return false }
        let since = now.timeIntervalSince(time)
        return since >= 0 && since < window
    }

    static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "RepoRadar, KeyBar and 2 more"
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// The oldest loose ends first, since they're the ones that get lost
    static func ordered(_ repos: [RepoStatus]) -> [RepoStatus] {
        repos.enumerated().sorted { a, b in
            switch (a.element.looseSince, b.element.looseSince) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    static func body(for repos: [RepoStatus], now: Date = Date()) -> String {
        let list = ordered(repos)
        var text = "\(names(list.map(\.name))) \(list.count == 1 ? "has" : "have") work that isn't committed or pushed."
        if let oldest = list.first, let since = oldest.looseSince, let waited = Waiting.duration(since: since, now: now) {
            text += list.count == 1 ? " It's been waiting \(waited)." : " \(oldest.name) has been waiting \(waited)."
        }
        return text
    }

    static func post(repos: [RepoStatus]) {
        let content = UNMutableNotificationContent()
        content.title = repos.count == 1 ? "1 repo has loose ends" : "\(repos.count) repos have loose ends"
        content.body = body(for: repos)
        let request = UNNotificationRequest(identifier: "reporadar.reminder", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
