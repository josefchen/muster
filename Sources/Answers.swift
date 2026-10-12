import AppKit

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
    /// The port hooks call. Kept across launches so installed hooks stay valid;
    /// moves to the next free one only if something else took it.
    private static let ports: ClosedRange<UInt16> = 47621...47640
    private(set) static var port: UInt16 = {
        let saved = UserDefaults.standard.integer(forKey: "hookPort")
        return ports.contains(UInt16(clamping: saved)) ? UInt16(clamping: saved) : ports.lowerBound
    }()
    static let maxHold: TimeInterval = 15 * 60

    private(set) var pending: [UUID: Prompt] = [:]
    private var replies: [UUID: (Data) -> Void] = [:]
    private var raw: [UUID: [String: Any]] = [:]
    private let server = HookServer(ports: Prompts.ports)
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
        server.onReady = { [weak self] in self?.adopt($0) }
        server.onRequest = { [weak self] in self?.handle($0, $1) }
        server.start(on: Self.port)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseIfWatched()
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.expire() }
    }

    /// Keeps the port the server got, and points this install's hooks at it.
    /// Another build's hooks, with another token, stay as they are.
    private func adopt(_ number: UInt16) {
        guard number != Self.port || UserDefaults.standard.integer(forKey: "hookPort") == 0 else { return }
        Self.port = number
        UserDefaults.standard.set(Int(number), forKey: "hookPort")
        for agent in [Agent.claude, .codex] where HookInstaller.hasStale(agent) { try? HookInstaller.repoint(agent) }
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
        Stats.record(.answered)
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

    private func handle(_ r: HTTPRequest, _ x: HookServer.Exchange) {
        guard r.headers["x-muster-token"] == token,
              let input = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
              let prompt = parse(r.path, input) else { x.reply(Data()); return }
        if prompt.blocksNative, let front = NSWorkspace.shared.frontmostApplication, isHost(front, of: prompt) {
            x.reply(Data())
            return
        }
        pending[prompt.id] = prompt
        replies[prompt.id] = x.reply
        raw[prompt.id] = input
        x.onClose { DispatchQueue.main.async { [weak self] in self?.drop(prompt.id); Store.shared.refreshPrompts() } }
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

// MARK: - Installing the hooks

/// Adds Muster's hooks to each agent's own settings, and removes exactly those
/// again. Every edit keeps a backup beside the original file.
enum HookInstaller {
    static var claudeSettings: String { (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude") + "/settings.json" }
    static var codexHooks: String { (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex") + "/hooks.json" }

    /// This install's hooks for the agent, if Muster answers it.
    private static func hooks(_ agent: Agent) -> Hooks? {
        switch agent {
        case .claude: return Hooks(agent: .claude, path: claudeSettings, port: Prompts.port, token: Prompts.shared.token)
        case .codex: return Hooks(agent: .codex, path: codexHooks, port: Prompts.port, token: Prompts.shared.token)
        case .cursor: return nil
        }
    }

    static func isInstalled(_ agent: Agent) -> Bool { hooks(agent)?.isInstalled ?? false }
    static func hasStale(_ agent: Agent) -> Bool { hooks(agent)?.isStale ?? false }
    static func install(_ agent: Agent) throws { try hooks(agent)?.install() }
    static func repoint(_ agent: Agent) throws { try hooks(agent)?.repoint() }
    static func uninstall(_ agent: Agent) throws { try hooks(agent)?.uninstall() }

    static func displayPath(_ agent: Agent) -> String {
        let path = agent == .claude ? claudeSettings : codexHooks
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Names of programs other apps' Claude hooks point at that no longer exist.
    /// Each one fails on every hook event it's attached to.
    static func brokenClaudeHooks() -> [String] {
        guard let d = SettingsFile.read(claudeSettings), let hooks = d["hooks"] as? [String: Any] else { return [] }
        var names: [String] = []
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for h in group["hooks"] as? [[String: Any]] ?? [] {
                    guard let program = missingProgram(h["command"] as? String) else { continue }
                    let name = (program as NSString).lastPathComponent
                    if !names.contains(name) { names.append(name) }
                }
            }
        }
        return names
    }

    static func removeBrokenClaudeHooks() throws {
        try SettingsFile.edit(claudeSettings) { d in
            var hooks = d["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                let kept: [[String: Any]] = (value as? [[String: Any]] ?? []).compactMap { group in
                    let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { missingProgram($0["command"] as? String) == nil }
                    guard !handlers.isEmpty else { return nil }
                    var g = group
                    g["hooks"] = handlers
                    return g
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            d["hooks"] = hooks.isEmpty ? nil : hooks
        }
    }

    /// The command's program, if it's an absolute path that isn't there.
    private static func missingProgram(_ command: String?) -> String? {
        guard var c = command?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        let program: String
        if let quote = c.first, quote == "'" || quote == "\"" {
            c.removeFirst()
            program = String(c.prefix { $0 != quote })
        } else {
            program = String(c.prefix { !$0.isWhitespace })
        }
        let expanded = program.replacingOccurrences(of: "$HOME", with: home).replacingOccurrences(of: "${HOME}", with: home)
        let path = expanded.hasPrefix("~/") ? home + expanded.dropFirst() : expanded
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
