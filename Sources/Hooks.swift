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

/// An agent's JSON settings, changed without losing anything of yours.
///
/// - `<file>.muster-original` is the file as it was before Muster first changed
///   it, and is never overwritten. If you delete it, the next edit saves the
///   oldest copy there is.
/// - `<file>.muster-backup` is the file as it was before the latest change.
/// - A symlinked file (into a dotfiles repo, say) stays a link and its target is
///   changed. The backups sit beside the link.
/// - The file keeps its permissions, and a read-only one isn't changed.
/// - The agent writes the file too. Right before replacing it Muster checks it
///   still holds what was read, and if not, redoes the change on the new content.
/// - A file that isn't a JSON object (broken, or with comments) is left alone.
enum SettingsFile {
    static let originalSuffix = ".muster-original"
    static let backupSuffix = ".muster-backup"

    static func read(_ path: String) -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap { try? parse($0, path) }
    }

    static func edit(_ path: String, _ change: (inout [String: Any]) throws -> Void) throws {
        let fm = FileManager.default
        let target = try resolve(path)
        for _ in 0..<5 {
            let before = fm.contents(atPath: target)
            if before == nil, fm.fileExists(atPath: target) { throw failure(path, "couldn't be read") }
            var d = try before.map { try parse($0, path) } ?? [:]
            let old = d as NSDictionary
            try change(&d)
            if (d as NSDictionary) == old { return }
            if before == nil {
                try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            } else if !fm.isWritableFile(atPath: target) {
                throw failure(path, "is read-only")
            }
            let out = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let mode = (try? fm.attributesOfItem(atPath: target))?[.posixPermissions] as? Int ?? 0o600
            let staged = try stage(out, beside: target, mode: mode)
            do {
                if let before { try backUp(before, path, mode: mode) }
            } catch {
                unlink(staged)
                throw error
            }
            // Last look: if the agent wrote the file meanwhile, start over from its version.
            guard fm.contents(atPath: target) == before else { unlink(staged); continue }
            guard rename(staged, target) == 0 else { let code = errno; unlink(staged); throw posix(code, path) }
            return
        }
        throw failure(path, "kept changing while Muster was editing it")
    }

    /// The error shown when Muster won't touch a file.
    static func failure(_ path: String, _ reason: String) -> NSError {
        NSError(domain: "Muster", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "\((path as NSString).abbreviatingWithTildeInPath) \(reason), so Muster left it alone."])
    }

    private static func posix(_ code: Int32, _ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey:
            "Muster couldn't write \((path as NSString).abbreviatingWithTildeInPath): \(String(cString: strerror(code)))."])
    }

    /// An empty file counts as no settings yet.
    private static func parse(_ data: Data, _ path: String) throws -> [String: Any] {
        if data.allSatisfy({ [9, 10, 13, 32].contains($0) }) { return [:] }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { throw failure(path, "isn't valid JSON") }
        guard let d = any as? [String: Any] else { throw failure(path, "isn't a JSON object") }
        return d
    }

    /// The file at the end of any symlinks.
    private static func resolve(_ path: String) throws -> String {
        var p = path
        for _ in 0..<32 {
            guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: p) else { return p }
            p = next.hasPrefix("/") ? next : ((p as NSString).deletingLastPathComponent as NSString).appendingPathComponent(next)
        }
        throw failure(path, "is a loop of symlinks")
    }

    private static func backUp(_ data: Data, _ path: String, mode: Int) throws {
        let fm = FileManager.default
        let original = path + originalSuffix, latest = path + backupSuffix
        if (try? fm.attributesOfItem(atPath: original)) == nil {
            // Earlier versions kept only .muster-backup; it's older than the file now.
            let earlier = (try? fm.attributesOfItem(atPath: latest))?[.type] as? FileAttributeType == .typeRegular
            try replace(original, with: (earlier ? fm.contents(atPath: latest) : nil) ?? data, mode: mode)
        }
        try replace(latest, with: data, mode: mode)
    }

    /// Swaps in a new file whole, never following a symlink at `path`.
    private static func replace(_ path: String, with data: Data, mode: Int) throws {
        let staged = try stage(data, beside: path, mode: mode)
        guard rename(staged, path) == 0 else { let code = errno; unlink(staged); throw posix(code, path) }
    }

    /// Writes a new file next to `path` with `mode`, ready to rename over it.
    private static func stage(_ data: Data, beside path: String, mode: Int) throws -> String {
        let staged = (path as NSString).deletingLastPathComponent + "/." + (path as NSString).lastPathComponent
            + ".muster-" + UUID().uuidString.prefix(8)
        let fd = open(staged, O_WRONLY | O_CREAT | O_EXCL, mode_t(mode & 0o777))
        guard fd >= 0 else { throw posix(errno, path) }
        defer { close(fd) }
        fchmod(fd, mode_t(mode & 0o777))   // open's mode is narrowed by the umask
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard written, fsync(fd) == 0 else { let code = errno; unlink(staged); throw posix(code, path) }
        return staged
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

    // How long the hooks wait for Muster.
    //
    // Claude shows its own dialog while its hook waits and takes the first
    // answer, so a long wait costs nothing there.
    //
    // Codex shows its prompt only once the hook returns. If Muster hung (a
    // crash closes the connection, and curl returns at once), Codex would show
    // nothing until curl gave up, so curl gives up after 10 minutes. Muster
    // lets go of a Codex prompt at 9, checked every 30 s, so it never offers an
    // answer curl is no longer waiting for, and Codex's prompt then appears as
    // usual. Codex's own timeout only backs curl up.
    static let claudeWait = 3600
    static let codexWait = 600
    static let codexHold: TimeInterval = 9 * 60
    static let holdSweep: TimeInterval = 30

    /// This install's hooks are there and call this port.
    var isInstalled: Bool { mine.contains(where: calls) }
    var commandForReview: String? { mine.filter(calls).compactMap { $0["command"] as? String }.first }

    /// Digest just the definitions owned by this install, including their event
    /// and matcher. A partial install must never inherit a completed check.
    var verificationDigest: String? {
        guard let settings = SettingsFile.read(path),
              settings["disableAllHooks"] as? Bool != true,
              let events = settings["hooks"] as? [String: Any] else { return nil }
        var definitions: [[String: Any]] = []
        for (event, _) in groups {
            let owned = (events[event] as? [[String: Any]] ?? []).flatMap { group -> [[String: Any]] in
                (group["hooks"] as? [[String: Any]] ?? []).filter { isMine($0) && calls($0) }.map {
                    ["event": event, "matcher": group["matcher"] ?? "", "handler": $0]
                }
            }
            guard !owned.isEmpty else { return nil }
            definitions += owned
        }
        guard !definitions.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["path": URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                                                                      "definitions": definitions], options: [.sortedKeys]) else { return nil }
        return HookVerification.digest(data)
    }

    /// This install's hooks call an earlier port: the server had to move.
    var isStale: Bool { mine.contains { !calls($0) } }

    /// The handler Muster adds for an event, or nil for events it doesn't use.
    private func handler(for event: String) -> [String: Any]? {
        switch (agent, event) {
        case (.claude, "PermissionRequest"):
            return ["type": "http", "url": base + "/claude/permission", "timeout": Self.claudeWait, "headers": ["X-Muster-Token": token]]
        case (.claude, "PreToolUse"):
            return ["type": "http", "url": base + "/claude/question", "timeout": Self.claudeWait, "headers": ["X-Muster-Token": token]]
        case (.codex, "PermissionRequest"):
            let command = "/usr/bin/curl -s --max-time \(Self.codexWait) -X POST -H 'Content-Type: application/json' " +
                "-H 'X-Muster-Token: \(token)' --data-binary @- \(base)/codex/permission || true"
            return ["type": "command", "command": command, "timeout": Self.codexWait + 30]
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
            guard d["hooks"] == nil || d["hooks"] is [String: Any] else {
                throw SettingsFile.failure(path, "has \"hooks\" that aren't an object")
            }
            var hooks = d["hooks"] as? [String: Any] ?? [:]
            for (event, group) in groups {
                guard hooks[event] == nil || hooks[event] is [Any] else {
                    throw SettingsFile.failure(path, "has \(event) hooks that aren't a list")
                }
                hooks[event] = Self.removing(from: hooks[event] as? [Any] ?? [], where: isMuster).kept + [group]
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
        try SettingsFile.edit(path) { Self.remove(from: &$0, where: isMuster) }
    }

    /// Takes the handlers `drop` picks out of every event, then any group or
    /// event that leaves empty. Entries it doesn't recognise stay as they are.
    static func remove(from d: inout [String: Any], where drop: ([String: Any]) -> Bool) {
        guard var hooks = d["hooks"] as? [String: Any] else { return }
        var changed = false
        for (event, value) in hooks {
            guard let list = value as? [Any] else { continue }
            let (kept, removed) = removing(from: list, where: drop)
            guard removed else { continue }
            changed = true
            hooks[event] = kept.isEmpty ? nil : kept
        }
        guard changed else { return }
        d["hooks"] = hooks.isEmpty ? nil : hooks
    }

    /// An event's hook groups without the handlers `drop` picks, and whether it picked any.
    private static func removing(from list: [Any], where drop: ([String: Any]) -> Bool) -> (kept: [Any], removed: Bool) {
        var removed = false
        let kept: [Any] = list.compactMap { item in
            guard var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] else { return item }
            let others = handlers.filter { !(($0 as? [String: Any]).map(drop) ?? false) }
            guard others.count < handlers.count else { return item }
            removed = true
            guard !others.isEmpty else { return nil }
            group["hooks"] = others
            return group
        }
        return (kept, removed)
    }
}
