import Foundation

/// What Muster did for you, counted on this Mac only: prompts answered without
/// switching apps, and jumps to a session. Kept per ISO week for twelve weeks.
enum Stats {
    enum Event: String { case answered, jumped }

    /// The assumptions behind the time estimate, shown wherever it is.
    static let secondsPerAnswer: TimeInterval = 15
    static let secondsPerJump: TimeInterval = 5

    struct Week {
        var answered = 0
        var jumps = 0
        var saved: TimeInterval { Double(answered) * Stats.secondsPerAnswer + Double(jumps) * Stats.secondsPerJump }
    }

    private static let key = "stats.weeks"
    static var store = UserDefaults.standard

    static func record(_ event: Event, at date: Date = Date()) {
        var weeks = store.dictionary(forKey: key) as? [String: [String: Int]] ?? [:]
        let id = week(date)
        weeks[id, default: [:]][event.rawValue, default: 0] += 1
        let keep = Set((0..<12).map { week(date.addingTimeInterval(-Double($0) * 7 * 86_400)) })
        store.set(weeks.filter { keep.contains($0.key) }, forKey: key)
    }

    static func week(of date: Date = Date()) -> Week {
        let counts = (store.dictionary(forKey: key) as? [String: [String: Int]] ?? [:])[week(date)] ?? [:]
        return Week(answered: counts[Event.answered.rawValue] ?? 0, jumps: counts[Event.jumped.rawValue] ?? 0)
    }

    static func week(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// "48 prompts answered without switching · 132 jumps · about 23 min saved"
    static func summary(_ w: Week) -> String {
        var parts = ["\(w.answered) prompt\(w.answered == 1 ? "" : "s") answered without switching",
                     "\(w.jumps) jump\(w.jumps == 1 ? "" : "s")"]
        if w.saved >= 60 { parts.append("about \(duration(w.saved)) saved") }
        return parts.joined(separator: "  ·  ")
    }

    static var assumption: String {
        "Time saved assumes about \(Int(secondsPerAnswer)) seconds per prompt answered from Muster and \(Int(secondsPerJump)) per jump."
    }

    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        return minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }
}
