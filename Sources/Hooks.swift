import Foundation

// The parts of answering prompts that need no app around them: reading a hook's
// HTTP request, and adding or removing Muster's hooks in an agent's settings.
// Answers.swift wires them to the server, the port and the token.

/// A hook's request: a POST with a Content-Length JSON body.
struct HTTPRequest {
    let path: String
    let headers: [String: String]
    let body: Data

    enum Parse { case complete(HTTPRequest), partial, invalid }

    /// A complete request, or `.partial` while more bytes are needed.
    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .partial }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return .partial }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .partial }
        return .complete(HTTPRequest(path: String(parts[1]), headers: headers, body: data[bodyStart..<(bodyStart + length)]))
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

/// Muster's hooks in one agent's settings file, for the install that calls
/// `port` with `token`.
struct Hooks {
    let agent: Agent
    let path: String
    let port: UInt16
    let token: String

    var base: String { "http://127.0.0.1:\(port)" }
    private var route: String { base + (agent == .codex ? "/codex/" : "/claude/") }

    var isInstalled: Bool {
        (try? String(contentsOfFile: path, encoding: .utf8))?.contains(route) == true
    }

    /// Hooks from an earlier port, rewritten after the server had to move.
    var isStale: Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.contains("X-Muster-Token") && !isInstalled
    }

    func install() throws {
        switch agent {
        case .claude:
            try SettingsFile.edit(path) { d in
                var hooks = d["hooks"] as? [String: Any] ?? [:]
                let header = ["X-Muster-Token": token]
                hooks["PermissionRequest"] = strip(hooks["PermissionRequest"]) + [
                    ["matcher": "*", "hooks": [["type": "http", "url": base + "/claude/permission", "timeout": 3600, "headers": header]]]]
                hooks["PreToolUse"] = strip(hooks["PreToolUse"]) + [
                    ["matcher": "AskUserQuestion|ExitPlanMode",
                     "hooks": [["type": "http", "url": base + "/claude/question", "timeout": 3600, "headers": header]]]]
                d["hooks"] = hooks
            }
        case .codex:
            try SettingsFile.edit(path) { d in
                var hooks = d["hooks"] as? [String: Any] ?? [:]
                let command = "/usr/bin/curl -s --max-time 3600 -X POST -H 'Content-Type: application/json' " +
                    "-H 'X-Muster-Token: \(token)' --data-binary @- \(base)/codex/permission || true"
                hooks["PermissionRequest"] = strip(hooks["PermissionRequest"]) + [
                    ["hooks": [["type": "command", "command": command, "timeout": 3600]]]]
                d["hooks"] = hooks
            }
        case .cursor:
            break
        }
    }

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
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { h in
                !((h["headers"] as? [String: Any])?["X-Muster-Token"] != nil
                  || (h["url"] as? String)?.hasPrefix(base) == true
                  || (h["command"] as? String)?.contains("X-Muster-Token") == true)
            }
            guard !handlers.isEmpty else { return nil }
            var g = group
            g["hooks"] = handlers
            return g
        }
    }
}
