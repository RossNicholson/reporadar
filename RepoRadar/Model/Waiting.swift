import Foundation

/// How long work has been waiting, from a day up: "1 day", "5 days", "3 weeks"
enum Waiting {
    static func duration(since date: Date, now: Date = Date()) -> String? {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return nil
        case 1: return "1 day"
        case ..<14: return "\(days) days"
        case ..<60: return "\(days / 7) weeks"
        case ..<365: return "\(days / 30) months"
        default: return days < 730 ? "a year" : "\(days / 365) years"
        }
    }
}
