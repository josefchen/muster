import Foundation

// CHANGELOG.md for the places outside the app, through the app's own parser
// (Sources/Changelog.swift). Run it with scripts/changelog.sh.

let site = "https://agentmuster.app/changelog"
let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard args.count >= 2, let text = try? String(contentsOfFile: args[0], encoding: .utf8) else {
    fail("usage: changelog <CHANGELOG.md> notes <version> | page <template.html> | feed")
}
let releases = Changelog.parse(text)
let released = releases.filter { $0.date != nil }

// MARK: Markdown

/// A title as a run-in head: its period back, unless it ends in its own mark.
func runIn(_ title: String) -> String { title.last.map { "?!.".contains($0) } == true ? title : title + "." }

/// The GitHub release notes, in the shape 1.0 and 1.1 shipped with.
func notes(_ r: Release) -> String {
    var out = ["**Muster \(r.shortVersion).** \(r.headline)", ""]
    out += r.items.map { "- **\(runIn($0.title))** \($0.body)" }
    for note in r.notes { out += ["", note] }
    out += ["", "**Install:** open Muster.dmg and drag Muster to Applications, or `brew install --cask josefchen/tap/muster` "
        + "(to update: `brew upgrade --cask muster`). Signed and notarized. macOS 14 or later, Apple silicon or Intel."]
    return out.joined(separator: "\n")
}

// MARK: HTML

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// The inline Markdown the changelog uses: `code`, **bold** and [links](url).
func inline(_ markdown: String) -> String {
    var s = escape(markdown)
    for (pattern, template) in [(#"`([^`]+)`"#, "<code>$1</code>"), (#"\*\*(.+?)\*\*"#, "<b>$1</b>"),
                                (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>")] {
        let re = try! NSRegularExpression(pattern: pattern)
        s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
    return s
}

func anchor(_ r: Release) -> String { "v" + r.version }

func day(_ r: Release) -> String { r.date.map(Changelog.day.string) ?? "" }

func body(_ r: Release) -> String {
    var out = "<ul>\n" + r.items.map { "  <li><b>\(inline(runIn($0.title)))</b> \(inline($0.body))</li>" }.joined(separator: "\n") + "\n</ul>"
    for note in r.notes { out += "\n<p class=\"note\">\(inline(note))</p>" }
    return out
}

func page(_ template: String) -> String {
    let marker = "<!-- releases -->"
    guard template.contains(marker) else { fail("the template has no \(marker)") }
    let articles = released.enumerated().map { i, r in
        """
        <article class="release" id="\(anchor(r))">
          <div class="when">
            <a class="ver" href="#\(anchor(r))">\(escape(r.shortVersion))</a>\(i == 0 ? "<span class=\"latest\">Latest</span>" : "")
            <time datetime="\(day(r))">\(Changelog.longDate(r.date!, locale: Locale(identifier: "en_US")))</time>
          </div>
          <div class="what">
            <h2>\(inline(r.headline))</h2>
        \(body(r).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
          </div>
        </article>
        """
    }
    return template.replacingOccurrences(of: marker, with: articles.joined(separator: "\n"))
}

func feed() -> String {
    let updated = released.first.map { day($0) + "T00:00:00Z" } ?? "1970-01-01T00:00:00Z"
    let entries = released.map { r in
        """
          <entry>
            <title>Muster \(escape(r.shortVersion)): \(escape(r.headline))</title>
            <link href="\(site)#\(anchor(r))"/>
            <id>\(site)#\(anchor(r))</id>
            <updated>\(day(r))T00:00:00Z</updated>
            <content type="html">\(escape("<p>\(inline(r.headline))</p>\n" + body(r)))</content>
          </entry>
        """
    }
    return """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Muster changelog</title>
      <subtitle>Everything new in Muster, newest first.</subtitle>
      <link href="\(site)"/>
      <link rel="self" href="\(site).xml"/>
      <id>\(site)</id>
      <updated>\(updated)</updated>
      <author><name>Muster</name></author>
    \(entries.joined(separator: "\n"))
    </feed>
    """
}

// MARK: commands

switch args[1] {
case "notes":
    guard args.count == 3 else { fail("usage: changelog <CHANGELOG.md> notes <version>") }
    guard let r = releases.first(where: { Changelog.same($0.version, args[2]) }), r.date != nil else {
        fail("CHANGELOG.md has no dated entry for \(args[2])")
    }
    print(notes(r))
case "page":
    guard args.count == 3, let template = try? String(contentsOfFile: args[2], encoding: .utf8) else {
        fail("usage: changelog <CHANGELOG.md> page <template.html>")
    }
    print(page(template), terminator: "")
case "feed":
    print(feed())
default:
    fail("unknown command \(args[1])")
}
