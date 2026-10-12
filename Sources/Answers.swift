import AppKit
import Network

// Answer an agent's prompt from Muster: permission requests, Claude's multiple
// choice questions and plan approvals, delivered by the agents' own hooks to a
// server on 127.0.0.1 and held until you decide.
//
// Claude Code shows its native permission dialog while the hook waits, and the
// first answer wins, so those are held until answered. A question or a Codex
// approval only reaches its native prompt once the hook returns, so Muster lets
// go as soon as you're looking at the app the agent runs in.

struct Prompt {
    enum Kind {
        case permission(tool: String, summary: String, canAlwaysAllow: Bool)
        case question(text: String, options: [String])
        case plan(String)
    }

    let id = UUID()
    let agent: Agent
    let sessionID: String
    let project: String
    let kind: Kind
    let created = Date()
    /// Native prompt waits for us; release when you look at the agent's app.
    let blocksNative: Bool

    var headline: String {
        switch kind {
        case .permission(let tool, _, _):
            switch tool {
            case "Bash": return "Wants to run"
            case "Write", "Edit", "MultiEdit": return "Wants to edit"
            case "WebFetch": return "Wants to fetch"
            default: return "Wants to use \(tool)"
            }
        case .question(let text, _): return text
        case .plan: return "Approve the plan?"
        }
    }

    var detail: String {
        switch kind {
        case .permission(_, let summary, _): return summary
        case .question(_, let options): return options.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: "   ")
        case .plan(let text): return String(text.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "")
        }
    }
}

enum Answer {
    case allow, alwaysAllow, deny, option(Int)
}

final class Prompts {
    static let shared = Prompts()
    static let port: UInt16 = 47621
    static let maxHold: TimeInterval = 15 * 60

    private(set) var pending: [UUID: Prompt] = [:]
    private var replies: [UUID: (Data) -> Void] = [:]
    private var raw: [UUID: [String: Any]] = [:]
    private var listener: NWListener?
    var onChange: (() -> Void)?

    lazy var token: String = {
        if let t = UserDefaults.standard.string(forKey: "hookToken") { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(t, forKey: "hookToken")
        return t
    }()

    /// A sample prompt on the first sample session, for `--demo` screenshots.
    func addDemoPrompt() {
        let p = Prompt(agent: .claude, sessionID: "Migrate auth to passkeys", project: "/work/atlas",
                       kind: .permission(tool: "Bash", summary: "npm run migrate -- --env staging", canAlwaysAllow: true), blocksNative: false)
        pending[p.id] = p
    }

    func prompt(for s: Session) -> Prompt? {
        pending.values.filter { $0.agent == s.agent && $0.sessionID == s.sid }.max { $0.created < $1.created }
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: .main)
        listener = l
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseIfWatched()
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.expire() }
    }

    // MARK: answering

    func answer(_ p: Prompt, _ a: Answer) {
        if Store.demo {
            drop(p.id)
            Store.shared.refreshPrompts()
            return
        }
        guard let reply = replies[p.id], let input = raw[p.id] else { return }
        var out: [String: Any]?
        switch (p.kind, a) {
        case (.permission, .allow), (.plan, .allow):
            out = decision(p, ["behavior": "allow"], input: input)
        case (.permission, .alwaysAllow):
            var d: [String: Any] = ["behavior": "allow"]
            if let suggestions = input["permission_suggestions"] as? [[String: Any]], !suggestions.isEmpty { d["updatedPermissions"] = suggestions }
            out = decision(p, d, input: input)
        case (.permission, .deny), (.plan, .deny):
            out = decision(p, ["behavior": "deny", "message": "Declined from Muster."], input: input)
        case (.question(let text, let options), .option(let i)) where options.indices.contains(i):
            var updated = input["tool_input"] as? [String: Any] ?? [:]
            updated["answers"] = [text: options[i]]
            out = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]]
        case (.question, .deny):
            out = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                                          "permissionDecisionReason": "The user dismissed the question from Muster."]]
        default:
            return
        }
        reply(out.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data())
        drop(p.id)
        Store.shared.refreshPrompts()
    }

    /// Claude's PermissionRequest and Codex's share a shape; ExitPlanMode arrives on PreToolUse.
    private func decision(_ p: Prompt, _ d: [String: Any], input: [String: Any]) -> [String: Any] {
        if case .plan = p.kind {
            let allow = d["behavior"] as? String == "allow"
            return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": allow ? "allow" : "deny",
                                           "permissionDecisionReason": allow ? "Approved from Muster." : "Keep planning."]]
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
    }

    /// Step aside without deciding; the agent's own prompt takes over.
    func release(_ id: UUID) {
        replies[id]?(Data())
        drop(id)
    }

    /// Once you've moved on in the agent itself (its transcript advanced past the
    /// prompt), the held hook is stale.
    func resolve(with sessions: [Session]) {
        for p in pending.values {
            guard let s = sessions.first(where: { $0.agent == p.agent && $0.sid == p.sessionID }) else { continue }
            if s.since > p.created.addingTimeInterval(1), s.status != .needsYou { release(p.id) }
        }
    }

    private func releaseIfWatched() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        for p in pending.values where p.blocksNative && isHost(front, of: p) { release(p.id) }
        Store.shared.refreshPrompts()
    }

    private func isHost(_ app: NSRunningApplication, of p: Prompt) -> Bool {
        if p.agent.bundleIDs.contains(app.bundleIdentifier ?? "") { return true }
        let probe = Session(agent: p.agent, sid: p.sessionID, status: .needsYou, since: p.created, title: "", project: p.project, appID: "")
        return ProcessHost.app(running: probe)?.processIdentifier == app.processIdentifier
    }

    private func expire() {
        for p in pending.values where Date().timeIntervalSince(p.created) > Self.maxHold { release(p.id) }
        Store.shared.refreshPrompts()
    }

    private func drop(_ id: UUID) {
        pending[id] = nil
        replies[id] = nil
        raw[id] = nil
        onChange?()
    }

    // MARK: HTTP

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(buffer) {
                self.handle(request, c)
            } else if !done, error == nil, buffer.count < 4 << 20 {
                self.read(c, buffer)
            } else {
                c.cancel()
            }
        }
    }

    private func handle(_ r: HTTPRequest, _ c: NWConnection) {
        let respond: (Data) -> Void = { body in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
        guard r.headers["x-muster-token"] == token,
              let input = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
              let prompt = parse(r.path, input) else { respond(Data()); return }
        if prompt.blocksNative, let front = NSWorkspace.shared.frontmostApplication, isHost(front, of: prompt) {
            respond(Data())
            return
        }
        pending[prompt.id] = prompt
        replies[prompt.id] = respond
        raw[prompt.id] = input
        c.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { DispatchQueue.main.async { self?.drop(prompt.id); Store.shared.refreshPrompts() } }
            if case .failed = state { DispatchQueue.main.async { self?.drop(prompt.id); Store.shared.refreshPrompts() } }
        }
        onChange?()
        Store.shared.refreshPrompts()
    }

    private func parse(_ path: String, _ d: [String: Any]) -> Prompt? {
        let sid = d["session_id"] as? String ?? ""
        let cwd = d["cwd"] as? String ?? ""
        let tool = d["tool_name"] as? String ?? ""
        let input = d["tool_input"] as? [String: Any] ?? [:]
        let agent: Agent = path.hasPrefix("/codex") ? .codex : .claude
        if path.hasSuffix("/permission") {
            let summary = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["description"] as? String)
                ?? (input["url"] as? String) ?? tool
            let canAlways = !((d["permission_suggestions"] as? [Any])?.isEmpty ?? true)
            return Prompt(agent: agent, sessionID: sid, project: cwd, kind: .permission(tool: tool, summary: summary, canAlwaysAllow: canAlways),
                          blocksNative: agent == .codex)
        }
        if path.hasSuffix("/question") {
            if tool == "ExitPlanMode" {
                return Prompt(agent: agent, sessionID: sid, project: cwd, kind: .plan(input["plan"] as? String ?? ""), blocksNative: true)
            }
            // One question at a time; several questions in one call go to the native UI.
            guard let qs = input["questions"] as? [[String: Any]], qs.count == 1, let q = qs.first,
                  q["multiSelect"] as? Bool != true, let text = q["question"] as? String,
                  let options = (q["options"] as? [[String: Any]])?.compactMap({ $0["label"] as? String }), !options.isEmpty
            else { return nil }
            return Prompt(agent: agent, sessionID: sid, project: cwd, kind: .question(text: text, options: Array(options.prefix(9))), blocksNative: true)
        }
        return nil
    }
}

private struct HTTPRequest {
    let path: String
    let headers: [String: String]
    let body: Data

    /// A complete request with a Content-Length body, or nil if more bytes are needed.
    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        path = String(parts[1])
        self.headers = headers
        body = data[bodyStart..<(bodyStart + length)]
    }
}

// MARK: - Installing the hooks

/// Adds Muster's hooks to each agent's own settings, and removes exactly those
/// again. Every edit keeps a backup beside the original file.
enum HookInstaller {
    static var claudeSettings: String { (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude") + "/settings.json" }
    static var codexHooks: String { (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex") + "/hooks.json" }
    private static var base: String { "http://127.0.0.1:\(Prompts.port)" }

    static func isInstalled(_ agent: Agent) -> Bool {
        switch agent {
        case .claude: return (try? String(contentsOfFile: claudeSettings, encoding: .utf8))?.contains(base + "/claude/") == true
        case .codex: return (try? String(contentsOfFile: codexHooks, encoding: .utf8))?.contains(base + "/codex/") == true
        case .cursor: return false
        }
    }

    static func install(_ agent: Agent) throws {
        switch agent {
        case .claude:
            try edit(claudeSettings) { d in
                var hooks = d["hooks"] as? [String: Any] ?? [:]
                let header = ["X-Muster-Token": Prompts.shared.token]
                hooks["PermissionRequest"] = strip(hooks["PermissionRequest"]) + [
                    ["matcher": "*", "hooks": [["type": "http", "url": base + "/claude/permission", "timeout": 3600, "headers": header]]]]
                hooks["PreToolUse"] = strip(hooks["PreToolUse"]) + [
                    ["matcher": "AskUserQuestion|ExitPlanMode",
                     "hooks": [["type": "http", "url": base + "/claude/question", "timeout": 3600, "headers": header]]]]
                d["hooks"] = hooks
            }
        case .codex:
            try edit(codexHooks) { d in
                var hooks = d["hooks"] as? [String: Any] ?? [:]
                let command = "/usr/bin/curl -s --max-time 3600 -X POST -H 'Content-Type: application/json' " +
                    "-H 'X-Muster-Token: \(Prompts.shared.token)' --data-binary @- \(base)/codex/permission || true"
                hooks["PermissionRequest"] = strip(hooks["PermissionRequest"]) + [
                    ["hooks": [["type": "command", "command": command, "timeout": 3600]]]]
                d["hooks"] = hooks
            }
        case .cursor:
            break
        }
    }

    static func uninstall(_ agent: Agent) throws {
        let path = agent == .claude ? claudeSettings : agent == .codex ? codexHooks : ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        try edit(path) { d in
            var hooks = d["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                let kept = strip(value)
                hooks[event] = kept.isEmpty ? nil : kept
            }
            d["hooks"] = hooks.isEmpty ? nil : hooks
        }
    }

    /// The event's hook groups without any of Muster's.
    private static func strip(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]] ?? []).compactMap { group in
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { h in
                !((h["url"] as? String)?.hasPrefix(base) == true || (h["command"] as? String)?.contains(base) == true)
            }
            guard !handlers.isEmpty else { return nil }
            var g = group
            g["hooks"] = handlers
            return g
        }
    }

    private static func edit(_ path: String, _ change: (inout [String: Any]) -> Void) throws {
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
        change(&d)
        let out = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
