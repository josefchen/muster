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
    /// The rest of what the agent sent, for the alert's details (⌥↓).
    var context = Context()
    var remoteHost: String?

    struct Context {
        var reason = ""                 // the agent's own one-line explanation, when it gives one
        var body = ""                   // the whole command, the edit's file and size, the plan, or the URL
        var code = false                // body is a command, shown in monospace
        var choices: [(label: String, note: String)] = []
    }

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
    private static let ports: ClosedRange<UInt16> = E2E.ports ?? 47621...47640
    private(set) static var port: UInt16 = {
        let saved = UserDefaults.standard.integer(forKey: "hookPort")
        return ports.contains(UInt16(clamping: saved)) ? UInt16(clamping: saved) : ports.lowerBound
    }()
    /// Claude's dialog is live alongside; Codex's waits for us (see Hooks.codexWait).
    static func maxHold(_ agent: Agent) -> TimeInterval { agent == .codex ? Hooks.codexHold : 15 * 60 }

    private(set) var pending: [UUID: Prompt] = [:]
    private var replies: [UUID: (Data) -> Void] = [:]
    private var releases: [UUID: () -> Void] = [:]   // local requests: step aside for the agent's own prompt
    private var deliveries: [UUID: (Data, @escaping (Bool) -> Void) -> Void] = [:]
    private var raw: [UUID: [String: Any]] = [:]
    private var guided: Set<UUID> = []
    private var remoteRequests: [UUID: String] = [:]
    private let server = HookServer(ports: Prompts.ports)
    var onChange: (() -> Void)?

    lazy var token: String = {
        if let t = UserDefaults.standard.string(forKey: "hookToken") { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(t, forKey: "hookToken")
        return t
    }()

    /// A sample prompt on a sample session, for `--demo` screenshots and recordings.
    func addDemoPrompt(_ agent: Agent = .claude) {
        let p = agent == .codex
            ? Prompt(agent: .codex, sessionID: "Port the parser to Rust", project: "/work/lexer",
                     kind: .permission(tool: "Bash", summary: "cargo test --workspace", canAlwaysAllow: false), blocksNative: false,
                     context: Prompt.Context(reason: "Run the whole test suite against the new Rust parser",
                                             body: "cargo test --workspace", code: true))
            : Prompt(agent: .claude, sessionID: "Migrate auth to passkeys", project: "/work/atlas",
                     kind: .permission(tool: "Bash", summary: "npm run migrate -- --env staging", canAlwaysAllow: true), blocksNative: false,
                     context: Prompt.Context(reason: "Create the passkey tables in the staging database",
                                             body: "npm run migrate -- --env staging", code: true))
        pending[p.id] = p
    }

    /// A sample multiple-choice question, for `--demo --question` screenshots of the details.
    func addDemoQuestion() {
        let options = [("Postgres", "Beside the users table, kept across restarts"),
                       ("Redis", "Expires on its own, one more service to run"),
                       ("In memory", "Simplest, but lost on every deploy")]
        let p = Prompt(agent: .claude, sessionID: "Migrate auth to passkeys", project: "/work/atlas",
                       kind: .question(text: "Where should passkey challenges live?", options: options.map(\.0)), blocksNative: true,
                       context: Prompt.Context(choices: options.map { (label: $0.0, note: $0.1) }))
        pending[p.id] = p
    }

    func prompt(for s: Session) -> Prompt? {
        return pending.values.filter { $0.agent == s.agent && $0.sessionID == s.sid && $0.remoteHost == s.remoteHost }
            .max { $0.created < $1.created }
    }

    /// The SSH stream supplies the host; a remote payload cannot choose another
    /// host or attach its approval to a local session with the same identifier.
    func receiveRemote(_ request: SSHApproval, host: String, reply: @escaping (Data) -> Void) {
        guard SSHHost.valid(host), let sid = request.input["session_id"] as? String, sid.utf8.count <= 256,
              var prompt = parse(request.path, request.input) else { reply(Data()); return }
        guard !pending.values.contains(where: { $0.remoteHost == host && remoteRequests[$0.id] == request.id }) else { return }
        prompt.remoteHost = host
        pending[prompt.id] = prompt
        remoteRequests[prompt.id] = request.id
        replies[prompt.id] = reply
        raw[prompt.id] = request.input
        onChange?()
        Store.shared.refreshPrompts()
    }

    func cancelRemote(_ host: String, request: String? = nil) {
        for p in pending.values where p.remoteHost == host && (request == nil || remoteRequests[p.id] == request) { drop(p.id) }
        Store.shared.refreshPrompts()
    }

    func start() {
        server.onReady = { [weak self] in self?.adopt($0) }
        server.onRequest = { [weak self] in self?.handle($0, $1) }
        server.start(on: Self.port)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseIfWatched()
        }
        // Common modes, so an open menu doesn't hold a Codex prompt past curl's limit.
        RunLoop.main.add(Timer(timeInterval: Hooks.holdSweep, repeats: true) { [weak self] _ in
            self?.expire()
            if let self { LocalShare.publish(port: Self.port, token: self.token) }
        }, forMode: .common)
    }

    /// Keeps the port the server got, and points this install's hooks at it.
    /// Another build's hooks, with another token, stay as they are.
    private func adopt(_ number: UInt16) {
        LocalShare.publish(port: number, token: token)
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
        let data = out.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        if let deliver = deliveries[p.id] {
            deliver(data) { success in
                HookSetup.shared.replied(p, success: success)
            }
        } else { reply(data) }
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
        if let release = releases[id] { release() } else { replies[id]?(Data()) }
        drop(id)
    }

    func endGuidedChecks() {
        for id in Array(guided) { release(id) }
        Store.shared.refreshPrompts()
    }

    /// Once you've moved on in the agent itself (its transcript advanced past the
    /// prompt), the held hook is stale.
    func resolve(with sessions: [Session]) {
        HookSetup.shared.progressed(sessions)
        for p in pending.values {
            guard p.remoteHost == nil, let s = sessions.first(where: { $0.agent == p.agent && $0.sid == p.sessionID }) else { continue }
            if s.since > p.created.addingTimeInterval(1), s.status != .needsYou { release(p.id) }
        }
    }

    private func releaseIfWatched() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        for p in pending.values where p.remoteHost == nil && p.blocksNative && isHost(front, of: p)
            && !(guided.contains(p.id) && HookSetup.shared.isGuidedCheck(p.agent)) { release(p.id) }
        Store.shared.refreshPrompts()
    }

    private func isHost(_ app: NSRunningApplication, of p: Prompt) -> Bool {
        if E2E.on { return E2E.front == p.agent }
        if p.agent.bundleIDs.contains(app.bundleIdentifier ?? "") { return true }
        let probe = Session(agent: p.agent, sid: p.sessionID, status: .needsYou, since: p.created, title: "", project: p.project, appID: "")
        return ProcessHost.app(running: probe)?.processIdentifier == app.processIdentifier
    }

    private func expire() {
        for p in pending.values where Date().timeIntervalSince(p.created) > Self.maxHold(p.agent)
            || (guided.contains(p.id) && !HookSetup.shared.isGuidedCheck(p.agent)) { release(p.id) }
        Store.shared.refreshPrompts()
    }

    private func drop(_ id: UUID) {
        pending[id] = nil
        replies[id] = nil
        releases[id] = nil
        raw[id] = nil
        deliveries[id] = nil
        guided.remove(id)
        remoteRequests[id] = nil
        onChange?()
    }

    // MARK: HTTP

    private func handle(_ r: HTTPRequest, _ x: HookServer.Exchange) {
        guard r.headers["x-muster-token"] == token,
              let input = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
              let prompt = parse(r.path, input) else { x.reply(Data()); return }
        HookSetup.shared.received(prompt)
        let checking = HookSetup.shared.isGuidedCheck(prompt.agent)
        if prompt.blocksNative, !checking, let front = NSWorkspace.shared.frontmostApplication, isHost(front, of: prompt) {
            HookSetup.shared.disconnected(prompt)
            x.release()
            return
        }
        pending[prompt.id] = prompt
        if checking { guided.insert(prompt.id) }
        replies[prompt.id] = x.reply
        releases[prompt.id] = x.release
        deliveries[prompt.id] = { x.deliver($0, completion: $1) }
        raw[prompt.id] = input
        x.onClose { DispatchQueue.main.async { [weak self] in
            HookSetup.shared.disconnected(prompt)
            self?.drop(prompt.id)
            Store.shared.refreshPrompts()
        } }
        onChange?()
        Store.shared.refreshPrompts()
    }

    private func parse(_ path: String, _ d: [String: Any]) -> Prompt? {
        let sid = d["session_id"] as? String ?? ""
        let cwd = d["cwd"] as? String ?? ""
        let tool = d["tool_name"] as? String ?? ""
        let input = d["tool_input"] as? [String: Any] ?? [:]
        guard ["/claude/permission", "/claude/question", "/codex/permission"].contains(path), !sid.isEmpty else { return nil }
        let agent: Agent = path.hasPrefix("/codex/") ? .codex : .claude
        if path.hasSuffix("/permission") {
            let command = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ")
            let summary = command ?? (input["file_path"] as? String) ?? (input["description"] as? String)
                ?? (input["url"] as? String) ?? tool
            let canAlways = !((d["permission_suggestions"] as? [Any])?.isEmpty ?? true)
            return Prompt(agent: agent, sessionID: sid, project: cwd, kind: .permission(tool: tool, summary: summary, canAlwaysAllow: canAlways),
                          blocksNative: agent == .codex, context: Self.context(tool, input, command, d))
        }
        if path.hasSuffix("/question") {
            if tool == "ExitPlanMode" {
                let plan = input["plan"] as? String ?? ""
                return Prompt(agent: agent, sessionID: sid, project: cwd, kind: .plan(plan), blocksNative: true,
                              context: Prompt.Context(body: plan))
            }
            // One question at a time; several questions in one call go to the native UI.
            guard let qs = input["questions"] as? [[String: Any]], qs.count == 1, let q = qs.first,
                  q["multiSelect"] as? Bool != true, let text = q["question"] as? String,
                  let options = (q["options"] as? [[String: Any]])?.compactMap({ $0["label"] as? String }), !options.isEmpty
            else { return nil }
            let notes = (q["options"] as? [[String: Any]] ?? []).map { $0["description"] as? String ?? "" }
            let choices = options.prefix(9).enumerated().map { (label: $0.element, note: notes.indices.contains($0.offset) ? notes[$0.offset] : "") }
            return Prompt(agent: agent, sessionID: sid, project: cwd, kind: .question(text: text, options: Array(options.prefix(9))), blocksNative: true,
                          context: Prompt.Context(choices: choices))
        }
        return nil
    }

    /// Why the agent asks and what exactly it would do, from the request itself.
    static func context(_ tool: String, _ input: [String: Any], _ command: String?, _ d: [String: Any]) -> Prompt.Context {
        var c = Prompt.Context()
        c.reason = (input["description"] as? String) ?? (input["justification"] as? String) ?? (d["reason"] as? String) ?? ""
        let lines = { (key: String) in ((input[key] as? String) ?? "").split(separator: "\n", omittingEmptySubsequences: false).count }
        let file = input["file_path"] as? String ?? ""
        switch tool {
        case "Edit":
            c.body = "\(file)\nreplaces \(lines("old_string")) line\(lines("old_string") == 1 ? "" : "s") with \(lines("new_string"))"
        case "MultiEdit":
            let n = (input["edits"] as? [Any])?.count ?? 0
            c.body = "\(file)\n\(n) edit\(n == 1 ? "" : "s")"
        case "Write":
            c.body = "\(file)\nwrites \(lines("content")) line\(lines("content") == 1 ? "" : "s")"
        case "WebFetch":
            c.body = [input["url"] as? String, input["prompt"] as? String].compactMap { $0 }.joined(separator: "\n")
        default:
            if let command {
                c.body = command
            } else {
                c.body = input.keys.sorted().prefix(4).map { "\($0): \(String(describing: input[$0]!).prefix(160))" }.joined(separator: "\n")
            }
            c.code = true
        }
        if c.reason == command { c.reason = "" }
        return c
    }
}

// MARK: - Installing the hooks

/// Adds Muster's hooks to each agent's own settings, and removes exactly those
/// again. SettingsFile keeps the copies beside the file.
enum HookInstaller {
    static var claudeSettings: String { (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude") + "/settings.json" }
    static var codexHooks: String { (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex") + "/hooks.json" }

    /// This install's hooks for the agent, if Muster answers it.
    private static func hooks(_ agent: Agent, port: UInt16 = Prompts.port, token: String = Prompts.shared.token) -> Hooks? {
        switch agent {
        case .claude: return Hooks(agent: .claude, path: claudeSettings, port: port, token: token)
        case .codex: return Hooks(agent: .codex, path: codexHooks, port: port, token: token)
        case .cursor: return nil
        }
    }

    static func isInstalled(_ agent: Agent) -> Bool { hooks(agent)?.isInstalled ?? false }
    static func hasStale(_ agent: Agent) -> Bool { hooks(agent)?.isStale ?? false }
    static var codexCommandForReview: String? { hooks(.codex)?.commandForReview }
    static func verificationDigest(_ agent: Agent) -> String? {
        guard let digest = hooks(agent)?.verificationDigest else { return nil }
        // Feature switches and trust changes in Codex config invalidate earlier evidence.
        guard agent == .codex else { return digest }
        let config = (codexHooks as NSString).deletingLastPathComponent + "/config.toml"
        let data = (try? Data(contentsOf: URL(fileURLWithPath: config))) ?? Data()
        return HookVerification.digest(Data(digest.utf8) + data)
    }
    static func install(_ agent: Agent) throws {
        try add(agent, port: Prompts.port, token: Prompts.shared.token)
        HookSetup.shared.refresh()
    }
    static func repoint(_ agent: Agent) throws { try hooks(agent)?.repoint(); HookSetup.shared.refresh() }
    static func uninstall(_ agent: Agent) throws {
        try remove(agent, port: Prompts.port, token: Prompts.shared.token)
        HookSetup.shared.refresh()
    }

    /// Installs or removes on a background queue and reports back on the main one. Sharing
    /// with Agent Relay runs Python, which can take seconds to start, and the switch in
    /// Settings or the tour shouldn't freeze Muster meanwhile.
    static func set(_ agent: Agent, _ on: Bool, done: @escaping (Error?) -> Void) {
        let port = Prompts.port, token = Prompts.shared.token
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try on ? add(agent, port: port, token: token) : remove(agent, port: port, token: token) } catch { failure = error }
            DispatchQueue.main.async {
                HookSetup.shared.refresh()
                done(failure)
            }
        }
    }

    /// Where Agent Relay already answers, shares its hook rather than adding a second one:
    /// two blocking hooks hold the agent until both return.
    private static func add(_ agent: Agent, port: UInt16, token: String) throws {
        guard agent != .cursor else { return }
        if LocalShare.relayHolds(path(agent)) || LocalShare.shared(agent, path(agent)) {
            guard let script = Bundle.main.url(forResource: "remote_approvals", withExtension: "py") else {
                throw NSError(domain: "Muster", code: 1, userInfo: [NSLocalizedDescriptionKey: "This copy of Muster is missing its approval helper."])
            }
            try LocalShare.enable(python: LocalShare.relayPython([claudeSettings, codexHooks]), script: script, port: port, token: token)
        } else {
            try hooks(agent, port: port, token: token)?.install()
        }
    }
    /// Turning one agent off while sharing gives both back to Relay: the shared hook covers both.
    private static func remove(_ agent: Agent, port: UInt16, token: String) throws {
        if LocalShare.shared(agent, path(agent)), let script = Bundle.main.url(forResource: "remote_approvals", withExtension: "py") {
            try LocalShare.disable(python: LocalShare.relayPython([claudeSettings, codexHooks]), script: script)
        }
        try hooks(agent, port: port, token: token)?.uninstall()
    }
    static func path(_ agent: Agent) -> String { agent == .claude ? claudeSettings : codexHooks }
    /// Agent Relay answers this agent now, without Muster.
    static func relayAlone(_ agent: Agent) -> Bool { agent != .cursor && LocalShare.relayHolds(path(agent)) && !isInstalled(agent) }
    static func sharedWithRelay(_ agent: Agent) -> Bool { agent != .cursor && LocalShare.shared(agent, path(agent)) }
    /// Relay's installer ran again and added its own hook beside the shared one, so the agent
    /// waits for both. Installing again folds it back in.
    static func relayAddedBack(_ agent: Agent) -> Bool { sharedWithRelay(agent) && LocalShare.relayHolds(path(agent)) }

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
        try SettingsFile.edit(claudeSettings) { Hooks.remove(from: &$0) { missingProgram($0["command"] as? String) != nil } }
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
