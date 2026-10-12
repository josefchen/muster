import Foundation

// The parts of answering prompts that need no app around them: reading a hook's
// HTTP request, and adding or removing Muster's hooks in an agent's settings.
// Answers.swift wires them to the server, the port and the token.

/// A hook's request: a POST with a Content-Length JSON body. Any local process
/// can connect, and this runs before the token is checked, so every input must
/// end in a request, a wait for more bytes, or a refusal.
struct HTTPRequest {
    let path: String
    /// Lowercased names. A repeated header's values are joined with ", ", so a
    /// second token header can't stand in for the first.
    let headers: [String: String]
    let body: Data

    enum Parse { case complete(HTTPRequest), partial, invalid }

    /// A hook sends a few hundred bytes of headers and a JSON body.
    static let maxHead = 16 << 10
    static let maxBody = 4 << 20

    static func parse(_ data: Data) -> Parse {
        let start = data.startIndex
        let window = start..<(start + min(data.count, maxHead + 4))
        guard let end = data.range(of: Data("\r\n\r\n".utf8), in: window) else {
            return window.count < maxHead + 4 ? .partial : .invalid
        }
        let lines = String(decoding: data[start..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].hasPrefix("/"), parts[2].hasPrefix("HTTP/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon]
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }) else { return .invalid }
            let key = name.lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if let seen = headers[key] {
                guard key != "content-length" else {
                    if seen == value { continue } else { return .invalid }
                }
                headers[key] = seen + ", " + value
            } else {
                headers[key] = value
            }
        }
        // Hooks never stream; a chunked body would leave the length ambiguous.
        guard headers["transfer-encoding"] == nil else { return .invalid }
        var length = 0
        if let text = headers["content-length"] {
            guard (1...9).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = Int(text), n <= maxBody else { return .invalid }
            length = n
        }
        guard data.endIndex - end.upperBound >= length else { return .partial }
        let body = Data(data[end.upperBound..<(end.upperBound + length)])
        return .complete(HTTPRequest(path: String(parts[1]), headers: headers, body: body))
    }
}

// MARK: - Settings files

/// An agent's JSON settings, read and changed in place.
enum SettingsFile {
    static func read(_ path: String) -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// Every edit keeps a backup beside the original file.
    static func edit(_ path: String, _ change: (inout [String: Any]) throws -> Void) throws {
        let fm = FileManager.default
        var d: [String: Any] = [:]
        if let data = fm.contents(atPath: path) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw NSError(domain: "Muster", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(path) isn't valid JSON, so Muster left it alone."])
            }
            d = parsed
            try? fm.removeItem(atPath: path + ".muster-backup")
            try fm.copyItem(atPath: path, toPath: path + ".muster-backup")
        } else {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try change(&d)
        let out = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - Muster's hooks

/// Muster's hooks in one agent's settings file, for the install that listens on
/// `port`. Each install has its own token, and a hook is that install's only if
/// it carries it, so a second copy of Muster (a test build has its own defaults)
/// never takes the hooks of the one you use.
struct Hooks {
    let agent: Agent
    let path: String
    let port: UInt16
    let token: String

    var base: String { "http://127.0.0.1:\(port)" }

    /// This install's hooks are there and call this port.
    var isInstalled: Bool { mine.contains(where: calls) }

    /// This install's hooks call an earlier port: the server had to move.
    var isStale: Bool { mine.contains { !calls($0) } }

    /// The handler Muster adds for an event, or nil for events it doesn't use.
    private func handler(for event: String) -> [String: Any]? {
        switch (agent, event) {
        case (.claude, "PermissionRequest"):
            return ["type": "http", "url": base + "/claude/permission", "timeout": 3600, "headers": ["X-Muster-Token": token]]
        case (.claude, "PreToolUse"):
            return ["type": "http", "url": base + "/claude/question", "timeout": 3600, "headers": ["X-Muster-Token": token]]
        case (.codex, "PermissionRequest"):
            let command = "/usr/bin/curl -s --max-time 3600 -X POST -H 'Content-Type: application/json' " +
                "-H 'X-Muster-Token: \(token)' --data-binary @- \(base)/codex/permission || true"
            return ["type": "command", "command": command, "timeout": 3600]
        default:
            return nil
        }
    }

    /// Muster's hook group for each event it uses.
    private var groups: [(event: String, group: [String: Any])] {
        switch agent {
        case .claude:
            return [("PermissionRequest", ["matcher": "*", "hooks": [handler(for: "PermissionRequest")!]]),
                    ("PreToolUse", ["matcher": "AskUserQuestion|ExitPlanMode", "hooks": [handler(for: "PreToolUse")!]])]
        case .codex:
            return [("PermissionRequest", ["hooks": [handler(for: "PermissionRequest")!]])]
        case .cursor:
            return []
        }
    }

    /// This install's handlers in the file.
    private var mine: [[String: Any]] {
        guard let hooks = SettingsFile.read(path)?["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { value in
            (value as? [Any] ?? []).flatMap { group in
                ((group as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            }
        }.filter(isMine)
    }

    private func isMine(_ h: [String: Any]) -> Bool {
        guard !token.isEmpty else { return false }
        return (h["headers"] as? [String: Any])?["X-Muster-Token"] as? String == token
            || (h["command"] as? String)?.contains("X-Muster-Token: \(token)'") == true
    }

    private func calls(_ h: [String: Any]) -> Bool {
        (h["url"] as? String)?.hasPrefix(base + "/") == true || (h["command"] as? String)?.contains(" \(base)/") == true
    }

    /// Any Muster's handler, this install's or another's.
    private func isMuster(_ h: [String: Any]) -> Bool {
        (h["headers"] as? [String: Any])?["X-Muster-Token"] != nil
            || (h["url"] as? String)?.hasPrefix(base + "/") == true
            || (h["command"] as? String)?.contains("X-Muster-Token") == true
    }

    /// Adds this install's hooks, replacing any Muster's: two answering the
    /// same prompt would race.
    func install() throws {
        guard agent != .cursor else { return }
        try SettingsFile.edit(path) { d in
            var hooks = d["hooks"] as? [String: Any] ?? [:]
            for (event, group) in groups {
                hooks[event] = strip(hooks[event]) + [group]
            }
            d["hooks"] = hooks
        }
    }

    /// Points this install's stale hooks at the current port, each where it
    /// was. Runs without asking, so it touches nothing else, not even another
    /// Muster's hooks.
    func repoint() throws {
        guard isStale else { return }
        try SettingsFile.edit(path) { d in
            guard var hooks = d["hooks"] as? [String: Any] else { return }
            for (event, value) in hooks {
                guard let fresh = handler(for: event), let list = value as? [Any] else { continue }
                hooks[event] = list.map { item -> Any in
                    guard var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] else { return item }
                    group["hooks"] = handlers.map { h -> Any in
                        guard let h = h as? [String: Any], isMine(h) else { return h }
                        return fresh
                    }
                    return group
                }
            }
            d["hooks"] = hooks
        }
    }

    /// Removes any Muster's hooks, so turning it off always leaves none behind.
    func uninstall() throws {
        guard agent != .cursor, FileManager.default.fileExists(atPath: path) else { return }
        try SettingsFile.edit(path) { d in
            var hooks = d["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                let kept = strip(value)
                hooks[event] = kept.isEmpty ? nil : kept
            }
            d["hooks"] = hooks.isEmpty ? nil : hooks
        }
    }

    /// The event's hook groups without any of Muster's.
    private func strip(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]] ?? []).compactMap { group in
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { !isMuster($0) }
            guard !handlers.isEmpty else { return nil }
            var g = group
            g["hooks"] = handlers
            return g
        }
    }
}
