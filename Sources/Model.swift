import AppKit

enum Agent: String, CaseIterable {
    case claude, codex, cursor

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var colour: NSColor {
        switch self {
        case .claude: return NSColor(srgbRed: 0.93, green: 0.55, blue: 0.20, alpha: 1)
        case .codex: return NSColor(srgbRed: 0.27, green: 0.52, blue: 0.98, alpha: 1)
        case .cursor: return NSColor(srgbRed: 0.62, green: 0.40, blue: 0.98, alpha: 1)
        }
    }

    var bundleIDs: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        }
    }

    /// The app's own icon, loaded once and pinned to a small representation.
    var icon: NSImage? {
        if let hit = Agent.icons[self] { return hit }
        guard let url = bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 64, height: 64)
        Agent.icons[self] = image
        return image
    }

    private static var icons: [Agent: NSImage] = [:]
}

/// Ordered by urgency: the switcher and the menu bar count read this order.
enum Status: Int, Comparable {
    case needsYou, error, working, done, idle

    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .error: return "Error"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    var colour: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .error: return .systemRed
        case .working: return .secondaryLabelColor
        case .done: return .systemGreen
        case .idle: return .tertiaryLabelColor
        }
    }

    var section: ListSection {
        switch self {
        case .needsYou, .error: return .attention
        case .working: return .working
        case .done, .idle: return .recent
        }
    }
}

enum ListSection: Int, CaseIterable {
    case attention, working, recent

    var title: String {
        switch self {
        case .attention: return "NEEDS YOU"
        case .working: return "WORKING"
        case .recent: return "RECENT"
        }
    }
}

/// Token counts by kind, which the APIs bill at different rates.
struct Usage: Equatable {
    var input = 0          // fresh input, excluding cache reads and writes
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var output = 0

    var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    static func + (a: Usage, b: Usage) -> Usage {
        Usage(input: a.input + b.input, cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
              cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
    }

    static func += (a: inout Usage, b: Usage) { a = a + b }
}

/// What a reader found on the last scan, for the Sources list in Settings.
enum SourceState: Equatable {
    case notInstalled
    case ok(Int)
    case unreadable(String)

    var summary: String {
        switch self {
        case .notInstalled: return "Not found on this Mac"
        case .ok(0): return "Installed, nothing in the last 3 hours"
        case .ok(let n): return "\(n) session\(n == 1 ? "" : "s") in the last 3 hours"
        case .unreadable(let why): return why
        }
    }
}

struct Session: Equatable {
    let agent: Agent
    let sid: String
    var status: Status
    var since: Date          // when the record that decided `status` was written
    var title: String
    var project: String      // workspace path, may be empty
    var appID: String        // id the app's deep link expects, when it differs from sid
    var tokens: Int = 0      // input (incl. cache) + output, 0 when the app records none
    var cached: Int = 0
    var cost: Double?        // at public API list prices; nil when no model could be priced
    var costPartial = false  // some tokens came from models with no known price
    var unread = false       // finished since you last opened it
    var promptID: UUID?      // a prompt waiting in Muster for your answer

    var id: String { "\(agent.rawValue):\(sid)" }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !project.isEmpty { return (project as NSString).lastPathComponent }
        return agent.name
    }

    var projectName: String { project.isEmpty ? "" : (project as NSString).lastPathComponent }

    /// Totals and the API-rate cost for usage broken down by model.
    mutating func account(_ byModel: [String: Usage]) {
        tokens = byModel.values.reduce(0) { $0 + $1.total }
        cached = byModel.values.reduce(0) { $0 + $1.cacheRead }
        var sum = 0.0, priced = false
        costPartial = false
        for (model, usage) in byModel where usage.total > 0 {
            if let c = Pricing.cost(usage, model: model) { sum += c; priced = true } else { costPartial = true }
        }
        cost = priced ? sum : nil
    }
}

func money(_ v: Double) -> String {
    if v < 1 { return String(format: "$%.2f", v) }
    if v < 1000 { return String(format: "$%.0f", v) }
    if v < 100_000 { return String(format: "$%.1fk", v / 1000) }
    return String(format: "$%.0fk", v / 1000)
}

func compact(_ n: Int) -> String {
    let v = Double(n)
    if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
    if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
    if v >= 1e3 { return String(format: "%.0fk", v / 1e3) }
    return "\(n)"
}

func age(_ since: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(since)))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h"
}

extension Session {
    /// Illustrative sessions for screenshots (`Muster --render <dir> --sample`).
    static var samples: [Session] {
        let now = Date()
        func make(_ agent: Agent, _ status: Status, _ ago: Double, _ title: String, _ project: String,
                  _ model: String?, _ tokens: Int, unread: Bool = false) -> Session {
            var s = Session(agent: agent, sid: title, status: status, since: now.addingTimeInterval(-ago), title: title,
                            project: "/work/" + project, appID: "", unread: unread)
            if let model {
                let t = Double(tokens)
                s.account([model: Usage(input: Int(t * 0.0004), cacheWrite5m: Int(t * 0.012), cacheWrite1h: Int(t * 0.018),
                                        cacheRead: Int(t * 0.965), output: Int(t * 0.0046))])
            }
            return s
        }
        return [
            make(.claude, .working, 40, "Migrate auth to passkeys", "atlas", "claude-opus-5-5", 84_200_000),
            make(.codex, .working, 12, "Port the parser to Rust", "lexer", "gpt-6-astra", 12_900_000),
            make(.cursor, .working, 5, "Polish the onboarding flow", "web", nil, 0),
            make(.claude, .working, 70, "Fix flaky CI on macOS runners", "atlas", "claude-sonnet-5", 412_000_000),
            make(.codex, .done, 300, "Write the 2.4 release notes", "docs", "gpt-6.1-sol", 3_400_000, unread: true),
            make(.claude, .done, 1500, "Profile the image pipeline", "media", "claude-opus-5-5", 1_240_000_000),
            make(.cursor, .done, 2900, "Add dark mode tokens", "web", nil, 0),
        ]
    }
}
