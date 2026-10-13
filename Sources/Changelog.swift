import Foundation

// CHANGELOG.md is the one place release notes are written. The app bundles it for
// What's New; scripts/changelog.sh turns it into the site's changelog page, its feed
// and the GitHub release notes. One parser for all of them, so they never disagree.
// The format is described in CONTRIBUTING.md.

struct Release: Equatable {
    struct Item: Equatable, Identifiable {
        let symbol: String    // an SF Symbol name
        let title: String     // without its closing period
        let body: String      // inline Markdown

        var id: String { title }
    }

    let version: String
    let date: Date?           // nil while unreleased
    var headline = ""
    var items: [Item] = []
    var notes: [String] = []  // paragraphs after the items, inline Markdown

    /// "1.2" for 1.2.0, the way Apple writes versions to people.
    var shortVersion: String { version.hasSuffix(".0") && version.split(separator: ".").count == 3 ? String(version.dropLast(2)) : version }
}

enum Changelog {
    static let defaultSymbol = "checkmark.circle"

    static func parse(_ text: String) -> [Release] {
        var releases: [Release] = []
        var paragraph: [String] = []
        var bullet: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty, !releases.isEmpty else { paragraph = []; return }
            let text = paragraph.joined(separator: " ")
            if releases[releases.count - 1].headline.isEmpty && releases[releases.count - 1].items.isEmpty {
                releases[releases.count - 1].headline = text
            } else {
                releases[releases.count - 1].notes.append(text)
            }
            paragraph = []
        }
        func flushBullet() {
            guard let lines = bullet, !releases.isEmpty else { bullet = nil; return }
            releases[releases.count - 1].items.append(item(lines.joined(separator: " ")))
            bullet = nil
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("## ") {
                flushBullet(); flushParagraph()
                releases.append(heading(String(raw.dropFirst(3))))
            } else if raw.hasPrefix("#") || releases.isEmpty {
                continue
            } else if line.isEmpty {
                flushBullet(); flushParagraph()
            } else if raw.hasPrefix("- ") || raw.hasPrefix("* ") {
                flushBullet(); flushParagraph()
                bullet = [String(line.dropFirst(2))]
            } else if bullet != nil {
                bullet?.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flushBullet(); flushParagraph()
        return releases
    }

    /// `1.2.0 · 2026-10-14`, or `· Unreleased`; an em dash works too.
    private static func heading(_ text: String) -> Release {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "·—"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let version = parts.first.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 } ?? text
        return Release(version: version, date: parts.dropFirst().first.flatMap { day.date(from: $0) })
    }

    /// `<!-- symbol --> **Title.** Body`, each part optional but the body.
    private static func item(_ text: String) -> Release.Item {
        var rest = Substring(text)
        var symbol = defaultSymbol
        if rest.hasPrefix("<!--"), let end = rest.range(of: "-->") {
            let name = rest[rest.index(rest.startIndex, offsetBy: 4)..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { symbol = name }
            rest = rest[end.upperBound...].drop { $0 == " " }
        }
        var title = ""
        if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**") {
            title = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
            if title.hasSuffix(".") { title.removeLast() }
            rest = rest[end.upperBound...].drop { $0 == " " }
        }
        return Release.Item(symbol: symbol, title: title, body: String(rest))
    }

    /// Calendar days are written without a time zone; read and show them in UTC so
    /// they never move a day.
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func longDate(_ date: Date, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateStyle = .long
        return f.string(from: date)
    }

    // MARK: versions

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func same(_ a: String, _ b: String) -> Bool { !newer(a, than: b) && !newer(b, than: a) }

    /// The last version before What's New existed: anyone who used Muster without a
    /// record of what they've seen came from it or earlier.
    static let firstWithoutWhatsNew = "1.1.0"

    /// The notes to show once after an update: the running version's own, if you
    /// used an earlier version. A first launch gets the tour instead.
    static func afterUpdate(to version: String, seen: String?, launchedBefore: Bool, in releases: [Release]) -> Release? {
        guard launchedBefore, newer(version, than: seen ?? firstWithoutWhatsNew) else { return nil }
        return releases.first { same($0.version, version) }
    }

    /// For the menu item: this version's notes, or else the newest release before it.
    static func current(_ version: String, in releases: [Release]) -> Release? {
        releases.first { same($0.version, version) } ?? releases.first { !newer($0.version, than: version) && $0.date != nil }
    }

    static let bundled: [Release] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()
}
