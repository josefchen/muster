import Foundation

/// The JSON each agent expects back from a hook, written out independently of the app.
enum Expect {
    static func permission(_ decision: [String: Any]) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }
    static let allow = permission(["behavior": "allow"])
    static let deny = permission(["behavior": "deny", "message": "Declined from Muster."])
    static func always(_ suggestions: [[String: Any]]) -> [String: Any] {
        permission(["behavior": "allow", "updatedPermissions": suggestions])
    }
    static func preToolUse(_ decision: String, _ reason: String) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": decision, "permissionDecisionReason": reason]]
    }
    static let planApproved = preToolUse("allow", "Approved from Muster.")
    static let planKept = preToolUse("deny", "Keep planning.")
    static let questionDismissed = preToolUse("deny", "The user dismissed the question from Muster.")
    static func answered(_ input: [String: Any], _ question: String, _ choice: String) -> [String: Any] {
        var updated = input
        updated["answers"] = [question: choice]
        return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]]
    }
}

/// The headless suite: the real app against a fixture home, driven through files,
/// hook requests and the control channel. Nothing appears on screen.
final class Headless {
    let app: App
    let fx: Fixture
    let seeded: (claude: ClaudeFixture, codex: CodexFixture, cursor: CursorFixture)
    let pulse: ClaudeFixture
    private var pulseWorking = false

    private var permissionURL: (port: UInt16, path: String) = (0, "")
    private var questionURL: (port: UInt16, path: String) = (0, "")
    private var claudeHeaders: [String: String] = [:]
    private var codexCommand = ""
    private let shellEnv: [String: String]

    private var pipeClaude: ClaudeFixture!
    private var pipeCodex: CodexFixture!
    private var pipeCursor: CursorFixture!
    private var hooked: ClaudeFixture!
    private let suggestions: [[String: Any]] = [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                                 "rules": [["toolName": "Bash", "ruleContent": "npm run migrate:*"]]]]

    /// Lays out a fixture home with a finished session per agent and hook settings of
    /// the user's own, before the first launch.
    static func seed(_ fx: Fixture) -> (ClaudeFixture, CodexFixture, CursorFixture, ClaudeFixture) {
        fx.mkdir(".claude/projects")
        fx.mkdir("Library/Application Support/Claude/claude-code-sessions")
        fx.mkdir(".cursor/projects")
        CodexFixture.createDB(fx)
        CursorFixture.createDB(fx)
        let t = Date().addingTimeInterval(-600)
        let c = ClaudeFixture(fx, project: "seeded")
        c.write(c.title("Seeded session"), c.user("Hello", at: t), c.reply("Hi.", at: t.addingTimeInterval(5)))
        let x = CodexFixture(fx, project: "seeded")
        x.write(x.turnContext(at: t), x.started(at: t), x.tokens(5000, at: t), x.completed(at: t.addingTimeInterval(30)))
        x.register(title: "Seeded thread")
        let u = CursorFixture(fx, project: "seeded")
        u.write(u.query("Seed the cache"), u.assistant("Seeded."), u.turnEnded())
        let p = ClaudeFixture(fx, project: "pulse")
        p.write(p.user("ping", at: t), p.reply("pong", at: t))
        fx.write(".claude/settings.json", json(["model": "opus", "hooks": ["PreToolUse": [
            ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/true"]]]]]]))
        fx.write(".codex/hooks.json", json(["hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]]]))
        return (c, x, u, p)
    }

    init(app: App, fx: Fixture, seeded: (ClaudeFixture, CodexFixture, CursorFixture, ClaudeFixture)) {
        self.app = app
        self.fx = fx
        self.seeded = (seeded.0, seeded.1, seeded.2)
        pulse = seeded.3
        shellEnv = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": fx.home]
    }

    func run() {
        startup()
        installHooks()
        setupChecks()
        pipeline()
        roundTrips()
        opening()
        remoteSessions()
        files()
        failSafe()
        abuse()
        sharedWithRelay()
    }

    // MARK: sharing with Agent Relay

    /// Stands in for Agent Relay's hook client: it holds each request until a file answers it,
    /// and notes when the shared hook withdraws its copy (SIGTERM to its process group).
    private static let relayClient = """
    import json, pathlib, signal, sys, time
    log = pathlib.Path(__file__).with_name("relay-log")
    log.mkdir(exist_ok=True)
    sid = json.loads(sys.stdin.read() or "{}").get("session_id", "none")
    (log / (sid + ".started")).write_text("1")
    def withdrawn(*_):
        (log / (sid + ".withdrawn")).write_text("1")
        sys.exit(0)
    signal.signal(signal.SIGTERM, withdrawn)
    answer = log / (sid + ".answer")
    while not answer.exists():
        time.sleep(.05)
    print(answer.read_text())
    """

    /// As Agent Relay's installer leaves things, Relay's hook holds every approval and
    /// Muster's are gone. Turning answering on must share, not race it.
    private func sharedWithRelay() {
        section("Hooks: shared with Agent Relay")
        let client = "Library/Application Support/AgentRelay/connector/hook-client.py"
        let relayLog = "Library/Application Support/AgentRelay/connector/relay-log/"
        fx.write(client, Data(Self.relayClient.utf8))
        func relay(_ agent: String) -> [String: Any] {
            ["type": "command", "command": "/usr/bin/python3 '\(fx.path(client))' \(agent) default", "timeout": 570]
        }
        app.post("/hooks", ["agent": "claude", "install": false])
        app.post("/hooks", ["agent": "codex", "install": false])
        var claude = fx.read(".claude/settings.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        var hooks = claude["hooks"] as? [String: Any] ?? [:]
        hooks["PermissionRequest"] = (hooks["PermissionRequest"] as? [Any] ?? []) + [["hooks": [relay("claude")]]]
        hooks["PreToolUse"] = (hooks["PreToolUse"] as? [Any] ?? []) + [["matcher": "AskUserQuestion|ExitPlanMode", "hooks": [relay("claude")]]]
        claude["hooks"] = hooks
        fx.write(".claude/settings.json", json(claude))
        var codex = fx.read(".codex/hooks.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        var codexHooks = codex["hooks"] as? [String: Any] ?? [:]
        codexHooks["PermissionRequest"] = (codexHooks["PermissionRequest"] as? [Any] ?? []) + [["hooks": [relay("codex")]]]
        codex["hooks"] = codexHooks
        fx.write(".codex/hooks.json", json(codex))
        check(app.state().map { !$0.hooks("claude") && !$0.hooks("codex") } == true,
              "with Relay holding the hooks and Muster's gone, Muster isn't answering")

        let r = app.post("/hooks", ["agent": "claude", "install": true])
        // Setup runs Relay's Python, whose first launch on a cold Mac can outlast the request.
        expect(app, "turning answering on shares Relay's hook rather than adding a second", within: 30) { _ in
            let text = String(decoding: self.fx.read(".claude/settings.json") ?? Data(), as: UTF8.self)
            return text.contains("Muster/approvals/hook.py") && !text.contains("AgentRelay/connector")
        }
        check(r == nil || (r?["installed"] as? Bool == true && r?["error"] == nil), "…without an error")
        let shared = String(decoding: fx.read(".claude/settings.json") ?? Data(), as: UTF8.self)
        let codexShared = String(decoding: fx.read(".codex/hooks.json") ?? Data(), as: UTF8.self)
        check(!shared.contains("AgentRelay/connector") && !codexShared.contains("AgentRelay/connector")
              && shared.contains("Muster/approvals/hook.py") && shared.contains(" local claude PermissionRequest")
              && codexShared.contains(" local codex PermissionRequest") && !shared.contains("X-Muster-Token"),
              "…one shared hook per agent now asks both; neither Relay's nor Muster's own is left to race it")
        check(app.state().map { $0.hooks("claude") && $0.hooks("codex") } == true, "…and Muster reports both agents answering")
        let endpoint = "Library/Application Support/Muster/approvals/muster.json"
        let published = fx.read(endpoint).flatMap(parseJSON) as? [String: Any]
        let mode = (try? FileManager.default.attributesOfItem(atPath: fx.path(endpoint))[.posixPermissions] as? Int) ?? 0
        check(published?["port"] as? Int == Int(app.state()?.hookPort ?? 0) && mode == 0o600,
              "the shared hook finds Muster's port and token in a private file")

        let settings = shared.data(using: .utf8).flatMap(parseJSON) as? [String: Any] ?? [:]
        let command = ((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
            .first { $0.contains("Muster/approvals/hook.py") } ?? "false"
        let first = ClaudeFixture(fx, project: "relay-share")
        first.write(first.user("Share it"), first.toolUse("Bash", input: ["command": "printf shared"]))
        let run = Shell(command, stdin: json(first.permissionPayload(command: "printf shared", suggestions: [])), env: shellEnv)
        let p = held("claude", first.sid, "permission", "a request through the shared hook raises Muster's alert")
        expect(app, "…and reaches Relay too") { _ in self.fx.read(relayLog + first.sid + ".started") != nil }
        answer(p, "allow")
        let out = run.wait(5)
        check(out?.status == 0 && sameJSON(out?.stdout, Expect.allow), "answering in Muster returns the allow to Claude")
        expect(app, "…and withdraws Relay's copy") { _ in self.fx.read(relayLog + first.sid + ".withdrawn") != nil }

        let second = ClaudeFixture(fx, project: "relay-answers")
        second.write(second.user("Relay it"), second.toolUse("Bash", input: ["command": "printf relayed"]))
        let run2 = Shell(command, stdin: json(second.permissionPayload(command: "printf relayed", suggestions: [])), env: shellEnv)
        _ = held("claude", second.sid, "permission", "another request raises the alert")
        fx.write(relayLog + second.sid + ".answer", json(Expect.deny))
        let out2 = run2.wait(5)
        check(out2?.status == 0 && sameJSON(out2?.stdout, Expect.deny), "answering in Relay returns its decision to Claude")
        expect(app, "…and takes Muster's alert down") { $0.prompt(agent: "claude", sid: second.sid) == nil }

        app.post("/hooks", ["agent": "claude", "install": false])
        let restored = String(decoding: fx.read(".claude/settings.json") ?? Data(), as: UTF8.self)
        let codexRestored = String(decoding: fx.read(".codex/hooks.json") ?? Data(), as: UTF8.self)
        check(restored.contains("AgentRelay/connector") && codexRestored.contains("AgentRelay/connector")
              && !restored.contains("Muster/approvals/hook.py") && !codexRestored.contains("Muster/approvals/hook.py")
              && app.state().map { !$0.hooks("claude") && !$0.hooks("codex") } == true,
              "turning it off gives both agents back to Relay's own hook")
    }

    // MARK: helpers
    // MARK: helpers

    /// Flips a sentinel session and waits for it, so every write before it has been scanned.
    private func settle() {
        pulseWorking.toggle()
        pulse.append(pulseWorking ? pulse.user("ping") : pulse.reply("pong"))
        let want = pulseWorking ? "working" : "done"
        if until(app, within: 8, { $0.status(self.pulse.id) == want }) == nil { note("(no rescan within 8 s)") }
    }

    private func loadHooks() {
        let settings = fx.read(".claude/settings.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        func first(_ event: String) -> [String: Any]? {
            (hooks[event] as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .first { ($0["headers"] as? [String: String])?["X-Muster-Token"] != nil }
        }
        func url(_ h: [String: Any]?) -> (UInt16, String) {
            let u = (h?["url"] as? String).flatMap(URLComponents.init(string:))
            return (UInt16(u?.port ?? 0), u?.path ?? "")
        }
        let perm = first("PermissionRequest")
        permissionURL = url(perm)
        questionURL = url(first("PreToolUse"))
        claudeHeaders = (perm?["headers"] as? [String: String] ?? [:]).merging(["Content-Type": "application/json"]) { a, _ in a }
        let codex = fx.read(".codex/hooks.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        codexCommand = ((codex["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
            .first { $0.contains("X-Muster-Token") } ?? ""
    }

    private func claudeHook(_ url: (port: UInt16, path: String), _ payload: [String: Any], headers: [String: String]? = nil,
                            timeout: Double = 30) -> Pending<Response?> {
        let h = headers ?? claudeHeaders
        return Pending { HTTP.request(url.port, "POST", url.path, headers: h, body: json(payload), timeout: timeout) }
    }

    private func codexHook(_ payload: [String: Any]) -> Shell { Shell(codexCommand, stdin: json(payload), env: shellEnv) }

    /// Waits for the prompt a hook request should have raised.
    private func held(_ agent: String, _ sid: String, _ kind: String, _ what: String) -> [String: Any]? {
        var found: [String: Any]?
        expect(app, what) { s in
            found = s.prompt(agent: agent, sid: sid)
            return found?["kind"] as? String == kind
        }
        return found
    }

    private func answer(_ prompt: [String: Any]?, _ a: String, option: Int? = nil) {
        var body: [String: Any] = ["prompt": prompt?["id"] as? String ?? "", "answer": a]
        if let option { body["option"] = option }
        app.post("/answer", body)
    }

    private func reply(_ p: Pending<Response?>, _ what: String, _ expected: [String: Any]) {
        let r = p.wait(5) ?? nil
        check(r?.isJSON == true && sameJSON(r?.body, expected), what, r == nil ? "no reply" : "")
    }

    private func released(_ p: Pending<Response?>, _ what: String, since: Date, within: Double = 1) {
        let r = p.wait(within + 2) ?? nil
        let t = p.finishedAfter(since) ?? 99
        check(r?.isEmpty200 == true && t < within, what, r == nil ? "no reply" : secs(t))
    }

    private func expectedURL(_ s: [String: Any]) -> String {
        let sid = s["sid"] as? String ?? ""
        switch s["agent"] as? String {
        case "claude":
            let appID = s["appID"] as? String ?? ""
            if appID.isEmpty { return "activate:claude" }
            return "claude://code/\(s["status"] as? String == "needsYou" ? "needs-input" : "continue")?session=\(appID)&source=muster"
        case "codex": return "codex://threads/\(sid)"
        default: return "cursor://anysphere.cursor-deeplink/agent?id=\(sid)"
        }
    }

    /// Waits for the next line in the open log and checks it.
    @discardableResult
    private func opened(_ what: String, after count: Int, url: String, sid: String, within: Double = 1.5) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < within {
            let log = fx.opened()
            if log.count > count {
                let last = log[count]
                let ok = last["url"] as? String == url && last["sid"] as? String == sid && log.count == count + 1
                check(ok, what, ok ? url : "got \(last["url"] as? String ?? "?")")
                return ok
            }
            pause(0.03)
        }
        check(false, what, "nothing opened")
        return false
    }

    private func nothingOpened(_ what: String, since count: Int) {
        pause(0.3)
        check(fx.opened().count == count, what)
    }

    // MARK: startup

    private func startup() {
        section("Startup")
        guard let s = app.state() else { return check(false, "the control channel answers") }
        check(true, "runs as \(App.bundleID) against the fixture home", "hook server on \(s.hookPort), not 47621-47640")
        let ids = [seeded.claude.id, seeded.codex.key, seeded.cursor.id]
        expect(app, "lists the sessions already on disk, one per agent", within: 5) { s in ids.allSatisfy { s.status($0) == "done" } }
        let now = app.state()
        check(ids.allSatisfy { now?.unread($0) == false }, "sessions that finished before the first launch count as read")
        check(now?.source("claude") == "ok:2" && now?.source("codex") == "ok:1" && now?.source("cursor") == "ok:1",
              "each source reports what it found")
        check(now?.prompts.isEmpty == true && !["switcher", "deck", "alert"].contains { now?.visible($0) == true },
              "nothing is held and no panel is up at rest")
        check(now?.whatsNew == app.version, "an update from 1.1 opens What's New for \(app.version)", "showing \(now?.whatsNew ?? "nothing")")
    }

    // MARK: installing hooks

    private func musterHooks(_ settings: [String: Any], _ event: String, port: UInt16) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []).flatMap { group -> [[String: Any]] in
            (group["hooks"] as? [[String: Any]] ?? []).map { h in
                var h = h
                h["matcher"] = group["matcher"]
                return h
            }
        }.filter {
            ($0["url"] as? String)?.hasPrefix("http://127.0.0.1:\(port)/") == true || ($0["command"] as? String)?.contains("X-Muster-Token") == true
        }
    }

    private func installHooks() {
        section("Hooks: install")
        let port = app.state()?.hookPort ?? 0
        let original = fx.read(".claude/settings.json")
        let r = app.post("/hooks", ["agent": "claude", "install": true])
        check(r?["installed"] as? Bool == true && r?["error"] == nil, "installs Claude's hooks into the fixture's settings.json")
        let settings = fx.read(".claude/settings.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        let perm = musterHooks(settings, "PermissionRequest", port: port)
        let pre = musterHooks(settings, "PreToolUse", port: port)
        let token = (perm.first?["headers"] as? [String: String])?["X-Muster-Token"] ?? ""
        check(perm.count == 1 && perm[0]["type"] as? String == "http" && perm[0]["url"] as? String == "http://127.0.0.1:\(port)/claude/permission"
              && perm[0]["timeout"] as? Int == 3600 && token.count >= 16,
              "PermissionRequest: one http hook with the token header and an hour's timeout")
        check(pre.count == 1 && pre[0]["matcher"] as? String == "AskUserQuestion|ExitPlanMode"
              && pre[0]["url"] as? String == "http://127.0.0.1:\(port)/claude/question"
              && (pre[0]["headers"] as? [String: String])?["X-Muster-Token"] == token,
              "PreToolUse: AskUserQuestion and ExitPlanMode go to /claude/question")
        let own = ((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []).contains { $0["matcher"] as? String == "Bash" }
        check(own && settings["model"] as? String == "opus", "the user's own hooks and settings are kept")
        check(original != nil && fx.read(".claude/settings.json.muster-original") == original
              && fx.read(".claude/settings.json.muster-backup") == original,
              "the file as it was is kept as .muster-original and .muster-backup")
        app.post("/hooks", ["agent": "claude", "install": true])
        let again = fx.read(".claude/settings.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        check(musterHooks(again, "PermissionRequest", port: port).count == 1 && musterHooks(again, "PreToolUse", port: port).count == 1,
              "installing twice doesn't add a second copy")

        let cr = app.post("/hooks", ["agent": "codex", "install": true])
        let codex = fx.read(".codex/hooks.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        let codexHook = musterHooks(codex, "PermissionRequest", port: port).first ?? [:]
        let cmd = codexHook["command"] as? String ?? ""
        check(cr?["installed"] as? Bool == true && cmd.hasPrefix("/usr/bin/curl ") && cmd.contains("X-Muster-Token: \(token)")
              && cmd.contains("http://127.0.0.1:\(port)/codex/permission") && cmd.hasSuffix("|| true")
              && (codex["hooks"] as? [String: Any])?["Stop"] != nil,
              "installs Codex's command hook (curl … || true) and keeps its other hooks")
        check(cmd.contains("--max-time 600 ") && codexHook["timeout"] as? Int == 630,
              "Codex's curl gives up after 10 minutes, inside the hook's 630 s timeout")

        app.post("/hooks", ["agent": "claude", "install": false])
        let removed = fx.read(".claude/settings.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        let kept = ((removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []).contains { $0["matcher"] as? String == "Bash" }
        check(musterHooks(removed, "PermissionRequest", port: port).isEmpty && musterHooks(removed, "PreToolUse", port: port).isEmpty && kept
              && app.state()?.hooks("claude") == false, "uninstalling removes exactly Muster's hooks")
        app.post("/hooks", ["agent": "claude", "install": true])
        check(app.state().map { $0.hooks("claude") && $0.hooks("codex") } == true, "both agents report their hooks installed")
        check(fx.read(".claude/settings.json.muster-original") == original, "…and .muster-original still holds the file from before Muster")
        loadHooks()
    }


    private func setupChecks() {
        section("Hook setup: real request, reply, resumed session")
        check(app.state()?.hookSetup("claude") == "unverified" && app.state()?.hookSetup("codex") == "unverified",
              "installing hooks alone leaves both agents unverified")
        let onboarding = app.post("/onboarding-state", ["step": 3])
        check(onboarding?["canContinue"] as? Bool == false && (onboarding?["pending"] as? [String])?.count == 2,
              "onboarding cannot claim completion while opted-in agents remain unverified")
        check(app.post("/onboarding-state", ["step": 4])?["title"] as? String == "Finish later",
              "the final step honestly labels deferred setup")

        app.post("/setup", ["agent": "claude"])
        let c = ClaudeFixture(fx, project: "verify-claude")
        c.write(c.user("Check connection"), c.toolUse("Bash", input: ["command": "printf check"]))
        expect(app, "the test session is visible", within: 5) { $0.status(c.id) == "working" }
        let payload = c.permissionPayload(command: "printf check", suggestions: [])
        _ = HTTP.request(permissionURL.port, "POST", permissionURL.path,
                         headers: ["X-Muster-Token": "wrong"], body: json(payload), timeout: 2)
        _ = HTTP.request(permissionURL.port, "POST", "/unrelated/permission", headers: claudeHeaders, body: json(payload), timeout: 2)
        check(app.state()?.hookSetup("claude") == "waiting", "wrong tokens and lookalike routes cannot verify setup")
        let req = claudeHook(permissionURL, payload)
        let p = held("claude", c.sid, "permission", "a real Claude request reaches setup")
        check(app.state()?.hookSetup("claude") == "received", "a received request is not marked complete")
        answer(p, "allow")
        reply(req, "the setup reply reaches the client with the exact allow JSON", Expect.allow)
        expect(app, "delivery is recorded separately from session progress") { $0.hookSetup("claude") == "replied" }
        pulse.append(pulse.user("Unrelated work"), pulse.reply())
        expect(app, "another session advances") { $0.status(self.pulse.id) == "done" }
        check(app.state()?.hookSetup("claude") == "replied", "another session cannot complete this connection check")
        c.append(c.toolResult(), c.reply("Connection checked"))
        expect(app, "only the matching session resuming completes Claude setup") { $0.hookSetup("claude") == "verified" }
        app.stop()
        check(app.launch(), "the app restarts with the same fixture")
        check(app.state()?.hookSetup("claude") == "verified", "verified evidence survives restart for the same hook definition")
        loadHooks()
        app.post("/setup", ["agent": "claude"])
        check(app.state()?.hookSetup("claude") == "waiting", "rechecking waits for new evidence rather than recycling the old transcript")
        app.stop()
        check(app.launch(), "the app restarts during an incomplete recheck")
        check(app.state()?.hookSetup("claude") == "unverified", "an incomplete recheck never restores a previous ready state")
        loadHooks()
        if let fd = Net.connect(permissionURL.port) {
            let body = json(payload)
            var head = "POST \(permissionURL.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            for (k, v) in claudeHeaders { head += "\(k): \(v)\r\n" }
            Net.send(fd, Data((head + "Content-Length: \(body.count)\r\n\r\n").utf8) + body)
            _ = held("claude", c.sid, "permission", "another request arrives for the recheck")
            close(fd)
        }
        // A closed request without an answer must not acquire reply evidence.
        expect(app, "a request answered outside Muster remains incomplete") { $0.hookSetup("claude") == "interrupted" }

        let x = CodexFixture(fx, project: "verify-codex")
        x.write(x.turnContext(), x.started())
        x.register(title: "Codex connection check")
        expect(app, "the Codex test session is visible") { $0.status(x.key) == "working" }
        app.post("/setup", ["agent": "codex"])
        app.act("front", ["agent": "codex"])
        let run = codexHook(x.permissionPayload(command: "printf check"))
        let xp = held("codex", x.id, "permission", "the installed Codex curl command reaches setup")
        x.append(x.tokens(100, at: Date().addingTimeInterval(2)))
        settle()
        check(app.state()?.prompt(agent: "codex", sid: x.id) != nil,
              "a token heartbeat cannot resolve a pending Codex approval")
        check(app.state()?.hookSetup("codex") == "received", "Codex is not ready merely because its command ran")
        app.act("front", ["agent": "codex"])
        check(app.state()?.prompt(agent: "codex", sid: x.id) != nil,
              "an explicit check holds the request while the user pastes its prompt in Codex")
        app.act("front", ["agent": NSNull()])

        answer(xp, "deny")
        let out = run.wait(5)
        check(out?.status == 0 && sameJSON(out?.stdout, Expect.deny), "the installed command returns the exact deny JSON")
        expect(app, "Codex setup waits for its transcript after sending the answer") { $0.hookSetup("codex") == "replied" }
        x.append(x.completed())
        expect(app, "a completed Codex round trip verifies setup") { $0.hookSetup("codex") == "verified" }
        fx.write(".codex/config.toml", Data("[features]\nhooks = false\n".utf8))
        check(app.state()?.hookSetup("codex") == "unverified", "changing Codex feature configuration invalidates previous evidence")
        fx.remove(".codex/config.toml")
        app.post("/setup", ["agent": "codex"])
        let cancelled = codexHook(x.permissionPayload(command: "printf check"))
        _ = held("codex", x.id, "permission", "a request is held for a fresh guided check")
        app.post("/setup", ["agent": "codex", "cancel": true])
        let handedBack = cancelled.wait(5)
        check(handedBack?.status == 0 && handedBack?.stdout.isEmpty == true,
              "skipping setup releases the test request without approving it")
        check(app.state()?.hookSetup("codex") == "unverified", "cancelling the check leaves setup explicitly incomplete")

        app.post("/hooks", ["agent": "codex", "install": false])
        check(app.state()?.hookSetup("codex") == "notInstalled", "uninstalling clears Codex readiness")
        app.post("/hooks", ["agent": "codex", "install": true])
        check(app.state()?.hookSetup("codex") == "unverified", "reinstalling does not silently restore old verification")
        app.post("/hooks", ["agent": "claude", "install": false])
        app.post("/hooks", ["agent": "codex", "install": false])
        let switchingOnly = app.post("/onboarding-state", ["step": 3])
        check(switchingOnly?["canContinue"] as? Bool == true && switchingOnly?["title"] as? String == "Use switching only",
              "users can deliberately continue with switching only without fake hook completion")
        app.post("/hooks", ["agent": "claude", "install": true])
        app.post("/hooks", ["agent": "codex", "install": true])

        loadHooks()
    }

    // MARK: status pipeline

    private func pipeline() {
        section("Status pipeline")
        let c = ClaudeFixture(fx, project: "pipeline")
        pipeClaude = c
        c.write(c.user("Tidy the build scripts"))
        expect(app, "Claude: a new prompt reads as working") { $0.status(c.id) == "working" }
        c.append(c.toolUse("Bash", input: ["command": "make lint"]), c.toolResult("clean"), c.ask())
        expect(app, "Claude: AskUserQuestion reads as needs you") { $0.status(c.id) == "needsYou" }
        expect(app, "…and the alert shows it") { $0.visible("alert") && $0.alertSession == c.id }
        expect(app, "…with ⌥Tab to go to it, and where to turn on answering when that's off") { s in
            let on = (s.raw["hooks"] as? [String: Bool])?["claude"] == true
            return s.alertHints == (on ? "⌥Tab Go to it, Approval missing here? Check the connection in Settings" : "⌥Tab Go to it, Reply from here: turn it on in Settings")
        }
        c.append(c.toolResult("SQLite"), c.reply("Switched the cache to SQLite."))
        expect(app, "Claude: the finished turn reads as done, unread") { $0.status(c.id) == "done" && $0.unread(c.id) == true }
        expect(app, "…and the alert goes away") { !$0.visible("alert") }
        app.post("/open", ["id": c.id])
        expect(app, "opening it marks it read") { $0.unread(c.id) == false }
        c.append(c.user("And the docs"), c.reply("Updated."))
        expect(app, "finishing another turn makes it unread again") { $0.status(c.id) == "done" && $0.unread(c.id) == true }
        c.append(c.user("Push it"), c.apiError())
        expect(app, "Claude: an API error reads as error") { $0.status(c.id) == "error" && $0.fault(c.id) == "API error" }
        c.append(c.user("Try again"), c.apiError("You've hit your session limit · resets 6pm (Europe/Madrid)", code: "rate_limit"))
        expect(app, "Claude: a usage limit stops it without asking for you") { $0.status(c.id) == "blocked" && $0.fault(c.id) == "Out of usage" }
        c.append(c.user("Try again"), c.reply("Pushed."))

        let x = CodexFixture(fx, project: "pipeline")
        pipeCodex = x
        x.write(x.turnContext(), x.started(), x.call("cargo build"))
        x.register(title: "Port the parser")
        expect(app, "Codex: a started task reads as working") { $0.status(x.key) == "working" }
        let run = codexHook(x.permissionPayload(command: "cargo test --workspace"))
        expect(app, "Codex: an approval request reads as needs you") { $0.status(x.key) == "needsYou" && $0.promptID(x.key) != nil }
        let p = app.state()?.prompt(agent: "codex", sid: x.id)
        answer(p, "allow")
        let out = run.wait(5)
        check(out?.status == 0 && sameJSON(out?.stdout, Expect.allow), "Codex: the hook prints the allow decision and exits 0")
        expect(app, "…and the thread is working again") { $0.status(x.key) == "working" && $0.promptID(x.key) == nil }
        x.append(x.output("test result: ok"), x.tokens(48_000), x.completed())
        expect(app, "Codex: a completed task reads as done, unread") { $0.status(x.key) == "done" && $0.unread(x.key) == true }

        let u = CursorFixture(fx, project: "pipeline")
        pipeCursor = u
        u.write(u.query("Add a dark mode toggle"))
        expect(app, "Cursor: a new chat reads as working") { $0.status(u.id) == "working" }
        u.header(name: "Dark mode toggle", blocking: true)
        expect(app, "Cursor: a blocking pending action reads as needs you") { $0.status(u.id) == "needsYou" }
        u.header(name: "Dark mode toggle", blocking: false)
        u.append(u.assistant("Added the toggle."), u.turnEnded())
        expect(app, "Cursor: turn_ended reads as done, unread") { $0.status(u.id) == "done" && $0.unread(u.id) == true }

        let now = Date()
        let stale = ClaudeFixture(fx, project: "stale")
        stale.write(stale.user("Long job", at: now.addingTimeInterval(-1500)), stale.toolUse("Bash", at: now.addingTimeInterval(-1260)))
        let ancient = ClaudeFixture(fx, project: "ancient")
        ancient.write(ancient.user("Old", at: now.addingTimeInterval(-11_400)), ancient.reply("Old.", at: now.addingTimeInterval(-11_100)))
        let untouched = ClaudeFixture(fx, project: "untouched")
        untouched.write(untouched.user("Quiet"), untouched.toolUse("Bash"))
        fx.touch(untouched.rel, now.addingTimeInterval(-4 * 3600))
        let waiting = ClaudeFixture(fx, project: "heuristic")
        waiting.write(waiting.user("Migrate", at: now.addingTimeInterval(-25)), waiting.toolUse("Bash", input: ["command": "rm -rf dist"], at: now.addingTimeInterval(-20)))
        waiting.appRecord(appID: "local_" + UUID().uuidString.lowercased(), title: "Migrate", mode: "default", activity: now.addingTimeInterval(-20))
        // Muster's hook is installed here, so real prompts arrive through it: a tool call that's
        // merely slow must not raise a false alarm. (Without the hook it's still guessed; see Tests/main.swift.)
        expect(app, "Claude: with the hook installed, a tool call unanswered 15 s stays working, not needs you") {
            $0.hooks("claude") && $0.status(waiting.id) == "working"
        }
        let s = app.state()
        check(s?.status(stale.id) == "idle", "a session working but silent for 20 minutes reads as idle")
        check(s?.status(ancient.id) == nil, "a session that finished over 3 hours ago is dropped")
        check(s?.status(untouched.id) == nil, "a transcript untouched for 3 hours isn't read")
        waiting.append(waiting.toolResult(), waiting.reply())
        expect(app, "…and it reads as done once answered in Claude") { $0.status(waiting.id) == "done" }
    }

    // MARK: hook round trips

    private func roundTrips() {
        section("Hooks: round trips")
        let h = ClaudeFixture(fx, project: "hooks")
        hooked = h
        h.write(h.user("Run the migrations"), h.toolUse("Bash", input: ["command": "npm run migrate"]))
        expect(app, "a Claude session to prompt from") { $0.status(h.id) == "working" }

        // Permission: allow, always allow, deny.
        let perm = h.permissionPayload(command: "npm run migrate", suggestions: suggestions)
        var req = claudeHook(permissionURL, perm)
        var p = held("claude", h.sid, "permission", "a Claude PermissionRequest is held as a prompt")
        let s = app.state()
        check(!req.isDone && p?["canAlwaysAllow"] as? Bool == true && p?["summary"] as? String == "npm run migrate" && p?["blocksNative"] as? Bool == false,
              "…waiting, with the command and an Always Allow option")
        check(s?.status(h.id) == "needsYou" && s?.promptID(h.id) == p?["id"] as? String, "…and the session needs you, with the prompt on its row")
        expect(app, "…and the alert shows it") { $0.visible("alert") && $0.alertSession == h.id }
        answer(p, "allow")
        reply(req, "Allow returns Claude's allow decision", Expect.allow)
        expect(app, "…and the prompt is gone, the session working again") { $0.prompts.isEmpty && $0.status(h.id) == "working" }

        req = claudeHook(permissionURL, perm)
        p = held("claude", h.sid, "permission", "another request is held")
        answer(p, "always")
        reply(req, "Always Allow passes permission_suggestions back as updatedPermissions", Expect.always(suggestions))

        req = claudeHook(permissionURL, perm)
        p = held("claude", h.sid, "permission", "another request is held")
        answer(p, "deny")
        reply(req, "Deny returns Claude's deny decision with a message", Expect.deny)

        // AskUserQuestion.
        let questions = ClaudeFixture.questions("Which database should the cache use?")
        req = claudeHook(questionURL, h.preToolUsePayload(tool: "AskUserQuestion", input: questions))
        p = held("claude", h.sid, "question", "AskUserQuestion is held as a question")
        check((p?["options"] as? [String]) == ["Postgres", "SQLite", "Redis"] && p?["blocksNative"] as? Bool == true, "…with its three options")
        expect(app, "…shown in the alert") { $0.visible("alert") && $0.alertSession == h.id }
        expect(app, "…which holds ⌥1–⌥3 and the arrows, and leaves ⌥↩, ⌥⌫ and the other digits to other apps") {
            $0.keys == ["⌥↑", "⌥↓", "⌥1", "⌥2", "⌥3"]
        }
        check(app.state()?.alertHints == "⌥1–⌥3 Choose, ⌥↓ Options", "…and names them", app.state()?.alertHints ?? "no hints")
        app.act("peek", ["open": true])
        expect(app, "⌥↓ lists every option with its note") { s in
            let d = s.panel("alert")["details"] as? String ?? ""
            return ["1", "Postgres", "Reuse the main database.", "2", "SQLite", "A file next to the app.", "Redis"].allSatisfy(d.contains)
        }
        answer(p, "option", option: 1)
        reply(req, "choosing option 2 allows the tool with the answer filled in", Expect.answered(questions, "Which database should the cache use?", "SQLite"))

        req = claudeHook(questionURL, h.preToolUsePayload(tool: "AskUserQuestion", input: questions))
        p = held("claude", h.sid, "question", "another question is held")
        answer(p, "deny")
        reply(req, "dismissing it denies the tool with a reason", Expect.questionDismissed)

        for (input, what) in [(ClaudeFixture.questions("Two at once?", count: 2), "several questions in one call"),
                              (ClaudeFixture.questions("Pick any", multiSelect: true), "a multiple-choice question")] {
            let r = HTTP.request(questionURL.port, "POST", questionURL.path, headers: claudeHeaders,
                                 body: json(h.preToolUsePayload(tool: "AskUserQuestion", input: input)), timeout: 3)
            check(r?.isEmpty200 == true && (r?.elapsed ?? 9) < 1 && app.state()?.prompts.isEmpty == true,
                  "\(what) goes straight back to Claude's own UI")
        }

        // ExitPlanMode.
        let plan = h.preToolUsePayload(tool: "ExitPlanMode", input: ["plan": "## Plan\n\n1. Add the cache table\n2. Backfill it"])
        req = claudeHook(questionURL, plan)
        p = held("claude", h.sid, "plan", "ExitPlanMode is held as a plan approval")
        answer(p, "allow")
        reply(req, "approving the plan allows ExitPlanMode", Expect.planApproved)
        req = claudeHook(questionURL, plan)
        p = held("claude", h.sid, "plan", "another plan is held")
        answer(p, "deny")
        reply(req, "Keep Planning denies it", Expect.planKept)

        // Codex.
        let x = CodexFixture(fx, project: "codex-hooks")
        x.write(x.turnContext(), x.started())
        x.register(title: "Codex hooks")
        expect(app, "a Codex thread to prompt from") { $0.status(x.key) == "working" }
        var run = codexHook(x.permissionPayload(command: "cargo test"))
        p = held("codex", x.id, "permission", "a Codex PermissionRequest, sent by the installed command, is held")
        answer(p, "allow")
        var out = run.wait(5)
        check(out?.status == 0 && sameJSON(out?.stdout, Expect.allow), "allowing prints Codex's allow decision")
        run = codexHook(x.permissionPayload(command: "cargo publish"))
        p = held("codex", x.id, "permission", "another Codex request is held")
        answer(p, "deny")
        out = run.wait(5)
        check(out?.status == 0 && sameJSON(out?.stdout, Expect.deny), "denying prints Codex's deny decision")

        // Requests that aren't Muster's own.
        let body = json(perm)
        let bad: [(String, [String: String], String, Data)] = [
            ("a wrong token", ["Content-Type": "application/json", "X-Muster-Token": "not-the-token"], permissionURL.path, body),
            ("no token", ["Content-Type": "application/json"], permissionURL.path, body),
            ("a body that isn't JSON", claudeHeaders, permissionURL.path, Data("{\"session_id\":".utf8)),
            ("an unknown path", claudeHeaders, "/claude/elsewhere", body),
        ]
        for (what, headers, path, data) in bad {
            let r = HTTP.request(permissionURL.port, "POST", path, headers: headers, body: data, timeout: 3)
            pause(0.1)
            check(r?.isEmpty200 == true && (r?.elapsed ?? 9) < 1 && app.state()?.prompts.isEmpty == true,
                  "\(what) gets an empty 200 at once and raises no prompt", r.map { secs($0.elapsed) } ?? "no reply")
        }

        // The answer keys, wherever the prompt shows.
        req = claudeHook(permissionURL, perm)
        p = held("claude", h.sid, "permission", "a request for the answer keys")
        expect(app, "…shown in the alert") { $0.visible("alert") && $0.alertSession == h.id }
        check(app.state()?.panel("alert")["details"] is NSNull, "…folded, with the details out of the way")
        check(app.state()?.alertHints == "⌥↩ Allow, ⌥⌫ Deny, ⌥↓ Details", "…and its keys named on it", app.state()?.alertHints ?? "no hints")
        expect(app, "…held while it shows: ⌥↩ ⌥⌫ and the arrows, but no digits or ⌥Esc") { s in
            ["⌥↩", "⌥⌫", "⌥↑", "⌥↓"].allSatisfy(s.keys.contains) && !s.keys.contains("⌥Esc") && !s.keys.contains("⌥1")
        }
        app.act("typing", ["on": true])
        expect(app, "typing in another app hands the keys back, so ⌥⌫ deletes a word there") { $0.keys.isEmpty && $0.visible("alert") }
        app.act("typing", ["on": false])
        expect(app, "…and they're held again once you stop") { $0.keys.contains("⌥↩") }
        app.act("peek", ["open": true])
        expect(app, "⌥↓ unfolds the agent's reason and the folder, without repeating a command the row shows whole") { s in
            let d = s.panel("alert")["details"] as? String ?? ""
            return d.contains("Run the migrations") && d.contains("hooks") && !d.contains("npm run migrate")
        }
        app.act("peek", ["open": false])
        expect(app, "⌥↑ folds them again") { $0.panel("alert")["details"] is NSNull }
        app.act("answer", ["answer": "allow"])
        reply(req, "⌥↩ with the alert up allows it", Expect.allow)
        expect(app, "with nothing asking, Muster holds no keys but ⌥Tab and search") { $0.keys.isEmpty }

        req = claudeHook(permissionURL, perm)
        p = held("claude", h.sid, "permission", "another, for the switcher")
        let opens = fx.opened().count
        app.act("hold", ["flags": ["option"]])
        app.act("next")
        expect(app, "…selected first in the switcher") { $0.visible("switcher") && $0.items("switcher").first == h.id && $0.selected("switcher") == 0 }
        app.act("answer", ["answer": "deny"])
        reply(req, "⌥⌫ in the switcher denies it", Expect.deny)
        expect(app, "…and closes the switcher") { !$0.visible("switcher") }
        app.act("release")
        nothingOpened("…without opening the session", since: opens)

        req = claudeHook(permissionURL, perm)
        p = held("claude", h.sid, "permission", "another, for the deck")
        app.act("search")
        expect(app, "…selected first in the deck") { $0.visible("deck") && $0.items("deck").first == h.id && $0.selected("deck") == 0 }
        app.act("answer", ["answer": "always"])
        reply(req, "⌥⇧↩ in the deck always allows it", Expect.always(suggestions))
        app.act("key", ["key": "escape"])

        // Letting go when you look at the agent's own app.
        var since = Date()
        req = claudeHook(questionURL, h.preToolUsePayload(tool: "AskUserQuestion", input: questions))
        p = held("claude", h.sid, "question", "a question is held")
        since = Date()
        app.act("front", ["agent": "claude"])
        released(req, "…and let go the moment Claude comes to the front, so its own UI asks", since: since)
        check(app.state()?.prompts.isEmpty == true, "…and the prompt is withdrawn")
        app.act("front", ["agent": NSNull()])

        req = claudeHook(permissionURL, perm)
        p = held("claude", h.sid, "permission", "a permission request is held")
        app.act("front", ["agent": "claude"])
        pause(0.5)
        check(!req.isDone && app.state()?.prompts.count == 1, "…and kept when Claude comes to the front, since Claude shows its dialog anyway")
        answer(p, "deny")
        reply(req, "…until answered", Expect.deny)
        app.act("front", ["agent": NSNull()])

        run = codexHook(x.permissionPayload(command: "cargo bench"))
        p = held("codex", x.id, "permission", "a Codex request is held")
        since = Date()
        app.act("front", ["agent": "codex"])
        out = run.wait(3)
        check(out?.status == 0 && out?.stdout.isEmpty == true && (out.map { $0.elapsed } ?? 99) - since.timeIntervalSince(run.started) < 1,
              "…and let go when Codex comes to the front, so Codex asks itself")
        app.act("front", ["agent": NSNull()])

        app.act("front", ["agent": "claude"])
        let early = HTTP.request(questionURL.port, "POST", questionURL.path, headers: claudeHeaders, body: json(plan), timeout: 3)
        check(early?.isEmpty200 == true && (early?.elapsed ?? 9) < 1 && app.state()?.prompts.isEmpty == true,
              "a plan arriving while Claude is in front goes straight to Claude")
        app.act("front", ["agent": NSNull()])

        // A prompt nobody has a transcript for still gets a row.
        let orphan = "orphan-" + UUID().uuidString.lowercased()
        var payload = perm
        payload["session_id"] = orphan
        req = claudeHook(permissionURL, payload)
        p = held("claude", orphan, "permission", "a request from a session no scan has seen is held")
        check(app.state()?.status("claude:" + orphan) == "needsYou", "…with a row of its own")
        answer(p, "deny")
        reply(req, "…and answered like any other", Expect.deny)
        expect(app, "…and the row goes with it") { $0.session("claude:" + orphan) == nil }

        // Answered in the agent's own dialog: it drops the hook request.
        if let fd = Net.connect(permissionURL.port) {
            let body = json(perm)
            var head = "POST \(permissionURL.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            for (k, v) in claudeHeaders { head += "\(k): \(v)\r\n" }
            Net.send(fd, Data((head + "Content-Length: \(body.count)\r\n\r\n").utf8) + body)
            _ = held("claude", h.sid, "permission", "a request is held")
            close(fd)
            expect(app, "…and withdrawn when Claude hangs up, as it does once you answer in its own dialog") { $0.prompts.isEmpty }
        }

        // Moving on in the agent itself.
        req = claudeHook(permissionURL, perm)
        p = held("claude", h.sid, "permission", "a request is held")
        pause(1.2)
        since = Date()
        h.append(h.toolResult("migrated"), h.reply("Migrations ran."))
        released(req, "…and let go once the transcript moves past it (answered in Claude)", since: since, within: 2)
        expect(app, "…and the session reads as done") { $0.prompts.isEmpty && $0.status(h.id) == "done" }
    }

    // MARK: opening

    private func openSession(_ id: String, _ url: String, _ sid: String, _ what: String) {
        let n = fx.opened().count
        app.post("/open", ["id": id])
        opened(what, after: n, url: url, sid: sid)
    }

    private func opening() {
        section("Opening")
        let linked = ClaudeFixture(fx, project: "linked")
        let linkedApp = "local_" + UUID().uuidString.lowercased()
        linked.write(linked.user("Plan the Zephyr migration"), linked.reply("Planned."))
        linked.appRecord(appID: linkedApp, title: "Zephyr migration")
        let asking = ClaudeFixture(fx, project: "asking")
        let askingApp = "local_" + UUID().uuidString.lowercased()
        asking.write(asking.user("Choose a cache"), asking.ask())
        asking.appRecord(appID: askingApp, title: "Cache choice")
        expect(app, "Claude.app sessions are listed with their local_ ids") {
            $0.session(linked.id)?["appID"] as? String == linkedApp && $0.status(asking.id) == "needsYou"
        }
        openSession(asking.id, "claude://code/needs-input?session=\(askingApp)&source=muster", asking.sid, "Claude waiting on you: its needs-input link")
        openSession(linked.id, "claude://code/continue?session=\(linkedApp)&source=muster", linked.sid, "Claude.app session: its continue link")
        openSession(pipeClaude.id, "activate:claude", pipeClaude.sid, "a CLI session with no app record brings Claude forward")
        openSession(pipeCodex.key, "codex://threads/\(pipeCodex.id)", pipeCodex.id, "Codex: codex://threads/<id>")
        openSession(pipeCursor.id, "cursor://anysphere.cursor-deeplink/agent?id=\(pipeCursor.sid)", pipeCursor.sid,
                    "Cursor: its Agents window link")
        expect(app, "…and each one reads as read") { s in [linked.id, pipeCodex.key, pipeCursor.id].allSatisfy { s.unread($0) == false } }
        asking.append(asking.toolResult("Redis"), asking.reply("Using Redis."))

        var n = fx.opened().count
        app.post("/open", ["url": "muster://open?id=\(pipeCodex.key)"])
        opened("muster://open?id=… opens that session", after: n, url: "codex://threads/\(pipeCodex.id)", sid: pipeCodex.id)
        guard var s = until(app, { $0.status(asking.id) == "done" }), let top = s.sessions.first else { return check(false, "a settled list to open from") }
        n = fx.opened().count
        app.post("/open", ["url": "muster://next"])
        opened("muster://next opens the most urgent session", after: n, url: expectedURL(top), sid: top["sid"] as? String ?? "")

        // The switcher, as the shortcut drives it.
        s = app.state() ?? s
        var pick = s.switcherPick
        n = fx.opened().count
        app.act("next")
        if let first = s.session(pick[0]) {
            opened("a quick tap of ⌥Tab opens the most urgent session", after: n, url: expectedURL(first), sid: first["sid"] as? String ?? "")
        }
        expect(app, "…and the panel isn't left up") { !$0.visible("switcher") }

        app.act("hold", ["flags": ["option"]])
        app.act("next")
        expect(app, "holding ⌥Tab shows the switcher: live sessions, then the latest five done") {
            $0.visible("switcher") && $0.items("switcher") == pick && $0.selected("switcher") == 0
        }
        check(app.state().map { ["⌥↑", "⌥↓", "⌥Esc", "⌥↩", "⌥⌫", "⌥9"].allSatisfy($0.keys.contains) } == true,
              "…and holds the arrows, ⌥Esc and the answer keys only while it's open")
        app.act("next")
        app.act("next")
        app.act("previous")
        expect(app, "Tab and ⇧Tab move the selection") { $0.selected("switcher") == 1 }
        app.act("down")
        expect(app, "so do the arrows") { $0.selected("switcher") == 2 }
        app.act("up")
        s = until(app) { $0.selected("switcher") == 1 } ?? s
        n = fx.opened().count
        app.act("release")
        if let target = s.session(pick[1]) {
            opened("letting go opens the selected session", after: n, url: expectedURL(target), sid: target["sid"] as? String ?? "")
        }
        expect(app, "…and closes the switcher") { !$0.visible("switcher") }

        app.act("hold", ["flags": ["option"]])
        app.act("next")
        expect(app, "the switcher again") { $0.visible("switcher") }
        n = fx.opened().count
        app.act("cancel")
        expect(app, "Esc closes it") { !$0.visible("switcher") }
        app.act("release")
        nothingOpened("…and letting go then opens nothing", since: n)

        app.act("hold", ["flags": ["option"]])
        app.act("next")
        s = until(app) { $0.visible("switcher") } ?? s
        pick = s.items("switcher")
        n = fx.opened().count
        app.act("click", ["panel": "switcher", "row": 2])
        if pick.count > 2, let target = s.session(pick[2]) {
            opened("clicking a row opens it", after: n, url: expectedURL(target), sid: target["sid"] as? String ?? "")
        }
        expect(app, "…and closes the switcher") { !$0.visible("switcher") }
        app.act("release")

        // The deck.
        app.act("search")
        expect(app, "⌃⌥Space opens the deck with every session") { $0.visible("deck") && $0.items("deck") == $0.ids && $0.panel("deck")["query"] as? String == "" }
        app.act("type", ["text": "zephyr"])
        expect(app, "typing filters the list") { $0.items("deck") == [linked.id] }
        n = fx.opened().count
        app.act("key", ["key": "cmd+1"])
        opened("⌘1 opens the first match", after: n, url: "claude://code/continue?session=\(linkedApp)&source=muster", sid: linked.sid)
        expect(app, "…and closes the deck") { !$0.visible("deck") }

        app.act("search")
        app.act("key", ["key": "down"])
        s = until(app) { $0.visible("deck") && $0.selected("deck") == 1 } ?? s
        check(s.selected("deck") == 1, "↓ moves down the deck")
        n = fx.opened().count
        app.act("key", ["key": "return"])
        if let id = s.items("deck").dropFirst().first, let target = s.session(id) {
            opened("Return opens the selected row", after: n, url: expectedURL(target), sid: target["sid"] as? String ?? "")
        }

        app.act("search")
        expect(app, "the deck again") { $0.visible("deck") }
        n = fx.opened().count
        app.act("key", ["key": "escape"])
        expect(app, "Esc closes it") { !$0.visible("deck") }
        app.act("search")
        expect(app, "…the shortcut opens it") { $0.visible("deck") }
        app.act("search")
        expect(app, "…and closes it again") { !$0.visible("deck") }
        nothingOpened("…without opening anything", since: n)

        // The alert.
        let one = ClaudeFixture(fx, project: "alert-one")
        one.write(one.user("Pick a queue"), one.ask("Which queue?"))
        expect(app, "a session starting to wait raises the alert") { $0.visible("alert") && $0.alertSession == one.id }
        n = fx.opened().count
        app.act("alert", ["part": "open"])
        opened("clicking the alert opens that session", after: n, url: "activate:claude", sid: one.sid)
        expect(app, "…and puts the alert away") { !$0.visible("alert") }
        let two = ClaudeFixture(fx, project: "alert-two")
        two.write(two.user("Pick a region"), two.ask("Which region?"))
        expect(app, "the next one raises it again") { $0.visible("alert") && $0.alertSession == two.id }
        n = fx.opened().count
        app.act("alert", ["part": "dismiss"])
        expect(app, "its close button dismisses it") { !$0.visible("alert") }
        nothingOpened("…without opening anything", since: n)
        one.append(one.toolResult("SQS"), one.reply("Queued."))
        two.append(two.toolResult("eu-west"), two.reply("Moved."))
        expect(app, "both finish") { $0.status(one.id) == "done" && $0.status(two.id) == "done" }
    }

    // MARK: files

    private func remoteSessions() {
        section("Remote sessions")
        app.act("front", ["agent": NSNull()])
        let sid = seeded.codex.sid
        let remoteID = "ssh:3:vml:codex:" + sid
        func summary(_ status: String = "needsYou", errors: [String] = [], relay: Bool = false) -> [String: Any] {
            ["protocol": 1, "hostname": "fixture-devbox", "user": "fixture", "errors": errors, "limited": false,
             "approvals": relay,
             "sessions": [["agent": "codex", "sid": sid, "status": status, "since": Date().timeIntervalSince1970 + 1,
                           "title": "Remote approval workflow", "project": "/work/lexer", "asking": "Which database should the cache use?"]]]
        }
        func capture(_ endpoint: String, _ name: String) {
            let result = app.post(endpoint, ["name": name])
            check(result?["captured"] as? Bool == true, "renders \(name)")
            if let source = result?["path"] as? String,
               let directory = ProcessInfo.processInfo.environment["MUSTER_E2E_DIAGNOSTICS"] {
                let target = URL(fileURLWithPath: directory).appendingPathComponent("ssh-ui")
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target.appendingPathComponent(name + ".png"))
            }
        }
        let firstFrame = Date()
        app.post("/remote-summary", ["host": "vml", "summary": summary()])
        check(Date().timeIntervalSince(firstFrame) < 2, "receiving the first SSH summary keeps the main thread responsive")
        expect(app, "a remote question appears beside the local session with the same ID") {
            $0.status(remoteID) == "needsYou" && $0.session(self.seeded.codex.key) != nil
        }
        expect(app, "the alert shows the remote question and says where to answer") {
            $0.alertSession == remoteID && $0.alertHints?.contains("Answer on vml") == true
        }
        check(app.state()?.promptID(remoteID) == nil, "a remote row never borrows a local approval connection")
        capture("/alert-capture", "ssh-alert")
        app.act("search")
        app.act("type", ["text": "vml"])
        expect(app, "searching by SSH host finds its session") { $0.items("deck") == [remoteID] }
        app.act("key", ["key": "escape"])
        app.post("/remote-summary", ["host": "simpc3", "summary": summary("working")])
        expect(app, "the same session ID on a second SSH host stays separate") { $0.session("ssh:6:simpc3:codex:" + sid) != nil }
        app.post("/remote-offline", ["host": "vml"])
        expect(app, "disconnecting keeps the last summary and marks it offline") { $0.session(remoteID)?["remoteOffline"] as? Bool == true }
        expect(app, "an offline request is clearly labelled in the alert") { $0.alertHints?.contains("vml offline") == true }
        app.post("/remote-summary", ["host": "vml", "summary": summary()])
        expect(app, "a new summary clears the offline state") { $0.session(remoteID)?["remoteOffline"] as? Bool == false }
        let beforeOpen = fx.opened().count
        app.post("/open", ["id": remoteID])
        opened("opening a remote Codex session routes to its SSH host", after: beforeOpen,
               url: "codex://threads/\(sid)?hostId=remote-ssh-discovered:vml", sid: sid)

        func request(_ id: String, sessionID: String? = nil, agent: String = "codex") -> [String: Any] {
            ["protocol": 1, "event": "prompt", "requestID": id, "path": "/\(agent)/permission",
             "input": ["session_id": sessionID ?? sid, "cwd": "/work/lexer", "tool_name": "Bash",
                       "tool_input": ["command": "printf remote-check"]]]
        }
        func answers(_ id: String) -> [[String: Any]] {
            ((app.post("/remote-answers", [:])?["answers"] as? [[String: Any]]) ?? [])
                .filter { $0["requestID"] as? String == id }
        }
        app.post("/remote-summary", ["host": "vml", "summary": summary("working", relay: true)])
        let first = UUID().uuidString, second = UUID().uuidString
        app.post("/remote-approval", ["host": "vml", "event": request(first)])
        expect(app, "a remote hook attaches to its host without borrowing the local session") {
            $0.promptID(remoteID) != nil && $0.promptID(self.seeded.codex.key) == nil
        }
        expect(app, "a live remote approval offers an answer and identifies its host") {
            $0.alertSession == remoteID && $0.alertHints?.contains("Connected to vml") == true && $0.alertHints?.contains("Allow") == true
        }
        capture("/alert-capture", "ssh-approval")
        app.post("/remote-approval", ["host": "vml", "event": request(first)])
        check(answers(first).isEmpty, "a duplicate SSH event does not release the original request")
        let secondHostID = "ssh:6:simpc3:codex:" + sid
        app.post("/remote-approval", ["host": "simpc3", "event": request(second)])
        let firstPrompt = app.state()?.promptID(remoteID) ?? ""
        app.post("/answer", ["prompt": firstPrompt, "answer": "deny"])
        expect(app, "answering one host leaves the other host's matching session pending") {
            $0.promptID(remoteID) == nil && $0.promptID(secondHostID) != nil
        }
        let body = answers(first).last?["body"] as? [String: Any]
        let hookOutput = body?["hookSpecificOutput"] as? [String: Any]
        check((hookOutput?["decision"] as? [String: Any])?["behavior"] as? String == "deny",
              "the remote agent receives the normal denial response")
        app.post("/remote-cancel", ["host": "vml", "requestID": second])
        check(app.state()?.promptID(secondHostID) != nil, "a cancellation from one host cannot clear another host")
        app.post("/remote-cancel", ["host": "simpc3", "requestID": second])
        expect(app, "a native answer cancels the matching remote request") { $0.promptID(secondHostID) == nil }
        let orphan = UUID().uuidString, orphanSID = UUID().uuidString
        let orphanID = "ssh:3:vml:claude:" + orphanSID
        app.post("/remote-approval", ["host": "vml", "event": request(orphan, sessionID: orphanSID, agent: "claude")])
        expect(app, "a remote approval appears before its transcript exists") { $0.promptID(orphanID) != nil }
        app.post("/remote-approval", ["host": "vml", "event": request(UUID().uuidString, sessionID: orphanSID, agent: "claude")])
        check(app.state()?.sessions.filter { $0["id"] as? String == orphanID }.count == 1,
              "parallel requests from an unscanned session share one row")
        let newest = app.state()?.promptID(orphanID) ?? ""
        app.post("/answer", ["prompt": newest, "answer": "deny"])
        expect(app, "answering one parallel request exposes the remaining request") {
            $0.promptID(orphanID) != nil && $0.promptID(orphanID) != newest
        }
        app.post("/remote-offline", ["host": "vml"])
        expect(app, "a disconnected approval remains labelled as cached and cannot be answered") {
            $0.session(orphanID)?["remoteOffline"] as? Bool == true && $0.promptID(orphanID) == nil
        }
        capture("/alert-capture", "ssh-approval-offline")
        app.post("/remote-summary", ["host": "vml", "summary": summary("working", relay: true)])
        expect(app, "reconnecting replaces the old cached approval") { $0.session(orphanID) == nil }
        let handedBack = UUID().uuidString
        app.post("/remote-approval", ["host": "vml", "event": request(handedBack)])
        app.post("/open", ["id": remoteID])
        check((answers(handedBack).last?["body"] as? [String: Any])?.isEmpty == true,
              "opening a remote session returns its decision to the agent")
        app.post("/remote-summary", ["host": "vml", "summary": summary(relay: true)])

        app.post("/settings-preview", ["width": 460, "dark": false])
        settle()
        let pressed = app.post("/settings-press", ["identifier": "ssh-host-vml"])?["pressed"] as? Bool == true
        check(pressed, "the native Settings toggle can disable an SSH host")
        expect(app, "disabling the host removes its summaries while local work stays") { $0.session(remoteID) == nil && $0.session(self.seeded.codex.key) != nil }
        app.post("/remote-summary", ["host": "vml", "summary": summary()])
        check(app.state()?.session(remoteID) == nil, "late summaries cannot re-enable a disabled host")
        app.post("/remote-enabled", ["host": "vml", "enabled": true])
        app.post("/remote-summary", ["host": "vml", "summary": summary(relay: true)])
        app.post("/remote-offline", ["host": "simpc3"])
        for (width, dark) in [(460, false), (390, false), (390, true)] {
            app.post("/settings-preview", ["width": width, "dark": dark])
            settle()
            let name = "ssh-settings-\(width)-\(dark ? "dark" : "light")"
            capture("/settings-capture", name)
        }
        app.post("/remote-enabled", ["host": "vml", "enabled": false])
        app.post("/remote-enabled", ["host": "simpc3", "enabled": false])
        expect(app, "turning remote monitoring off leaves no remote sessions") { !$0.sessions.contains { $0["remoteHost"] is String } }
    }

    private func bigLine(_ c: ClaudeFixture, bytes: Int) -> Data {
        var d = Data(("{\"type\":\"user\",\"timestamp\":\"\(iso(Date()))\",\"sessionId\":\"\(c.sid)\",\"cwd\":\"\(c.cwd)\"," +
                      "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_big\",\"content\":\"").utf8)
        d.append(Data(repeating: 0x61, count: bytes))
        d.append(Data("\"}]}}\n".utf8))
        return d
    }

    private func footprint() -> String {
        guard let u = app.usage() else { return "" }
        return "footprint \(mb(u.footprint)), peak \(mb(u.peak))"
    }

    private func files() {
        section("Files")
        let batch = CodexFixture(fx, project: "question-batch")
        let call = "call_e2e_batch"
        batch.write(batch.turnContext(), batch.started(), jsonLine(["timestamp": iso(Date()), "type": "response_item", "payload": [
            "type": "function_call", "name": "request_user_input_async", "call_id": call,
            "arguments": String(decoding: json(["questions": [["title": "First batch question"], ["title": "Second batch question"]]]), as: UTF8.self)]]), batch.completed())
        batch.register(title: "Question batch")
        expect(app, "a Codex batch shows its first question") { $0.session(batch.key)?["asking"] as? String == "First batch question (and 1 more)" }
        expect(app, "the batch raises its alert") { $0.alertSession == batch.key }
        check(app.state()?.alertHints?.contains("Check the connection") == false, "a Codex question does not suggest that approval setup is broken")
        app.act("alert", ["part": "dismiss"])
        func reply(_ index: Int) {
            let id = String(decoding: json(["request_user_input_async", call, index] as [Any]), as: UTF8.self)
            let body = String(decoding: json([["questionItemId": id, "answer": "Yes"]]), as: UTF8.self)
            batch.append(jsonLine(["timestamp": iso(Date()), "type": "response_item", "payload": ["type": "message", "role": "user", "content": [
                ["text": "<send_user_message_question_reply>" + body + "</send_user_message_question_reply>"]]]]))
        }
        reply(0)
        expect(app, "answering one item leaves the second question waiting") { $0.status(batch.key) == "needsYou" && $0.session(batch.key)?["asking"] as? String == "Second batch question" }
        expect(app, "the remaining question raises a fresh alert after the first was dismissed") { $0.alertSession == batch.key }
        reply(1)
        expect(app, "answering the complete batch clears it") { $0.status(batch.key) == "done" && $0.session(batch.key)?["asking"] is NSNull }
        let long = CodexFixture(fx, project: "long-turn")
        let old = Date().addingTimeInterval(-1800)
        long.write(long.turnContext(at: old), long.started(at: old), long.tokens(100, at: Date()))
        long.register(title: "Long-running task")
        expect(app, "a Codex turn older than twenty minutes stays working while tokens arrive") { $0.status(long.key) == "working" }
        let quiet = CodexFixture(fx, project: "quiet-turn")
        quiet.write(quiet.turnContext(at: old), quiet.started(at: old), quiet.tokens(100, at: old))
        quiet.register(title: "Quiet task")
        expect(app, "a Codex turn becomes idle once its activity is stale") { $0.status(quiet.key) == "idle" }
        quiet.append(quiet.tokens(200))
        expect(app, "fresh Codex activity brings an idle task back to working") { $0.status(quiet.key) == "working" }
        quiet.append(quiet.completed())
        long.append(long.completed())
        expect(app, "long Codex tasks still move to done when they finish") { $0.status(long.key) == "done" && $0.status(quiet.key) == "done" }

        let f = ClaudeFixture(fx, project: "files")
        f.write(f.user("Read the logs"), f.reply("Read them."))
        expect(app, "a fresh transcript reads as done") { $0.status(f.id) == "done" }

        let line = f.toolUse("Bash", input: ["command": "tail -n 200 app.log"])
        let cut = line.count / 2
        f.append(Data(line[line.startIndex..<line.startIndex + cut]))
        settle()
        check(app.alive && app.state()?.status(f.id) == "done", "a half-written last line is left alone")
        f.append(Data(line[(line.startIndex + cut)...]))
        expect(app, "…and read once it's finished") { $0.status(f.id) == "working" }

        let before = fx.size(f.rel)
        f.append(f.toolResult("200 lines"), f.reply("All clear."))
        expect(app, "more lines: done") { $0.status(f.id) == "done" }
        fx.truncate(f.rel, to: before)
        expect(app, "a transcript cut back to an earlier line reads from what's left") { $0.status(f.id) == "working" }
        fx.truncate(f.rel, to: 0)
        expect(app, "an emptied transcript drops the session") { $0.status(f.id) == nil }
        f.append(f.user("Start over"))
        expect(app, "…and new lines bring it back") { $0.status(f.id) == "working" }

        fx.move(f.rel, to: f.rel + ".1")
        expect(app, "a transcript rotated aside drops the session") { $0.status(f.id) == nil }
        f.write(f.user("Fresh file"), f.reply("Fresh."))
        expect(app, "…and a new file under the same name takes over") { $0.status(f.id) == "done" }

        let big = bigLine(f, bytes: 50 << 20)
        f.append(big, f.reply("Summarised the dump."))
        expect(app, "a 50 MB line followed by a reply reads as done", within: 10) { $0.status(f.id) == "done" }
        note(footprint())
        f.append(big)
        settle()
        let s = app.state()
        check(app.alive && s?.status(f.id) == "working", "a 50 MB line as the newest record keeps the session, working",
              s?.status(f.id).map { "reads \($0)" } ?? (app.alive ? "the session is gone" : "the app \(app.exitDescription)"))
        f.append(f.reply("Done with the dump."))
        expect(app, "…and the next line reads normally", within: 10) { $0.status(f.id) == "done" }
        note(footprint())
        settle()
        settle()
        note("a few seconds later: " + footprint())

        var bad = Data(("{\"type\":\"assistant\",\"timestamp\":\"\(iso(Date()))\",\"message\":{\"stop_reason\":\"tool_use\"," +
                        "\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"").utf8)
        bad.append(contentsOf: [0xFF, 0xFE, 0xC3, 0x28, 0xED, 0xA0, 0x80])
        bad.append(Data("\"}}]}}\n".utf8))
        f.append(bad)
        settle()
        check(app.alive && app.state()?.status(f.id) == "done", "Claude: a line that isn't UTF-8 is skipped")
        f.append(f.user("Next"))
        expect(app, "…and the lines after it read normally") { $0.status(f.id) == "working" }

        let x = CodexFixture(fx, project: "files")
        x.write(x.turnContext(), x.started())
        x.register(title: "Files")
        expect(app, "a Codex thread to break") { $0.status(x.key) == "working" }
        var badCodex = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"".utf8)
        badCodex.append(contentsOf: [0xC0, 0xAF, 0xFF])
        badCodex.append(Data("\"}}\n".utf8))
        x.append(badCodex)
        settle()
        check(app.alive && app.state()?.status(x.key) == "working", "Codex: a rollout line that isn't UTF-8 is skipped")
        x.append(x.completed())
        expect(app, "…and the next event reads normally") { $0.status(x.key) == "done" }

        let u = CursorFixture(fx, project: "files")
        var badCursor = Data("{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"".utf8)
        badCursor.append(contentsOf: [0xFE, 0xFF, 0x80])
        badCursor.append(Data("\"}]}}\n".utf8))
        u.write(badCursor, u.turnEnded())
        expect(app, "Cursor: a first line that isn't UTF-8 leaves the chat listed, untitled") { $0.status(u.id) == "done" }

        fx.remove(f.rel)
        expect(app, "a deleted Claude transcript drops its session") { $0.status(f.id) == nil }
        fx.remove(x.rel)
        expect(app, "a deleted Codex rollout drops its thread") { $0.status(x.key) == nil }
        fx.remove(u.rel)
        expect(app, "a deleted Cursor transcript drops its chat") { $0.status(u.id) == nil }

        let g = ClaudeFixture(fx, project: "locked")
        g.write(g.user("Locked"), g.reply("Locked."))
        expect(app, "a session in a project folder about to be locked") { $0.status(g.id) == "done" }
        fx.chmod(g.dir, 0o000)
        expect(app, "an unreadable project folder drops only its own sessions") { $0.status(g.id) == nil && $0.status(self.seeded.claude.id) == "done" }
        fx.chmod(g.dir, 0o755)
        expect(app, "…which come back once it's readable", within: 7) { $0.status(g.id) == "done" }

        let db = ".codex/state_5.sqlite"
        fx.chmod(db, 0o000)
        expect(app, "an unreadable Codex database shows as unreadable", within: 7) { $0.source("codex") == "unreadable" }
        fx.chmod(db, 0o644)
        expect(app, "…and recovers", within: 7) { $0.source("codex")?.hasPrefix("ok") == true && $0.status(self.seeded.codex.key) == "done" }

        let saved = fx.read(CursorFixture.dbRel) ?? Data()
        fx.write(CursorFixture.dbRel, Data(repeating: 0x5A, count: 16_384))
        expect(app, "a corrupt Cursor database shows as unreadable", within: 7) { $0.source("cursor") == "unreadable" }
        fx.write(CursorFixture.dbRel, saved)
        expect(app, "…and recovers", within: 7) { $0.source("cursor")?.hasPrefix("ok") == true }

        fx.chmod(".cursor/projects", 0o000)
        expect(app, "an unreadable Cursor projects folder drops its file-only chats", within: 7) { $0.status(self.seeded.cursor.id) == nil }
        fx.chmod(".cursor/projects", 0o755)
        expect(app, "…which come back", within: 7) { $0.status(self.seeded.cursor.id) == "done" }
        check(app.alive, "the app came through every file case")
    }

    // MARK: fail-safe

    private func failSafe() {
        section("Fail-safe")
        guard let before = app.state() else { return check(false, "state before the kill") }
        let h = hooked!
        let req = claudeHook(permissionURL, h.permissionPayload(command: "npm run seed", suggestions: suggestions))
        _ = held("claude", h.sid, "permission", "a Claude request is held")
        let run = codexHook(pipeCodex.permissionPayload(command: "cargo clean"))
        _ = held("codex", pipeCodex.id, "permission", "and a Codex one")
        let killed = Date()
        app.kill9()
        _ = req.wait(3)
        let t = req.finishedAfter(killed) ?? 99
        check(req.isDone && t < 1, "kill -9: the held Claude request ends at once, so Claude falls back to its own dialog", secs(t))
        let out = run.wait(3)
        let ct = out.map { $0.elapsed - killed.timeIntervalSince(run.started) } ?? 99
        check(out?.status == 0 && out?.stdout.isEmpty == true && ct < 1, "…and the held Codex hook exits 0 with no output, so Codex asks itself", secs(ct))

        let down = codexHook(pipeCodex.permissionPayload(command: "cargo doc")).wait(5)
        check(down?.status == 0 && down?.stdout.isEmpty == true && (down?.elapsed ?? 99) < 1,
              "with the app down, the Codex hook (curl … || true) returns at once and succeeds", down.map { secs($0.elapsed) } ?? "hung")
        let t0 = Date()
        let refused = HTTP.request(permissionURL.port, "POST", permissionURL.path, headers: claudeHeaders, body: json(["session_id": "x"]), timeout: 3)
        check(refused == nil && Date().timeIntervalSince(t0) < 1, "…and Claude's hook URL refuses at once")

        let stable = before.sessions.filter { ["done", "idle"].contains($0["status"] as? String ?? "") && $0["promptID"] is NSNull }
        guard app.launch() else { return check(false, "the app relaunches") }
        expect(app, "relaunched: nothing is held over") { $0.prompts.isEmpty }
        check(app.state()?.whatsNew == nil, "relaunched: What's New doesn't open a second time")
        app.post("/open", ["url": "muster://whats-new"])
        expect(app, "…but muster://whats-new opens it") { $0.whatsNew == self.app.version }
        expect(app, "relaunched: finished sessions come back as they were, read or unread", within: 5) { s in
            stable.allSatisfy { old in
                let id = old["id"] as? String ?? ""
                return s.status(id) == old["status"] as? String && s.unread(id) == old["unread"] as? Bool
            }
        }
        loadHooks()
        let s = app.state()
        check(s.map { $0.hooks("claude") && $0.hooks("codex") && permissionURL.port == $0.hookPort } == true,
              "relaunched: the installed hooks reach the server", "port \(s?.hookPort ?? 0)\(s?.hookPort == before.hookPort ? ", unchanged" : ", moved and rewritten")")
        let req2 = claudeHook(permissionURL, h.permissionPayload(command: "npm run seed", suggestions: suggestions))
        let p = held("claude", h.sid, "permission", "relaunched: a new request is held")
        answer(p, "allow")
        reply(req2, "…and answered", Expect.allow)
    }

    // MARK: abuse

    private var hookPort: UInt16 { permissionURL.port }

    private func healthy(_ what: String) {
        pause(0.3)
        guard app.alive else {
            check(false, "\(what): the app stays up", "the app \(app.exitDescription)")
            for frame in app.crashFrames.prefix(4) { note(frame) }
            if !app.launch() { fatal("the app won't relaunch") }
            loadHooks()
            return
        }
        let r = HTTP.request(hookPort, "POST", "/claude/permission", headers: ["X-Muster-Token": "wrong"], body: Data("{}".utf8), timeout: 3)
        check(r?.isEmpty200 == true && (r?.elapsed ?? 9) < 1 && app.state() != nil, "\(what): the app stays up and keeps answering",
              r.map { secs($0.elapsed) } ?? "no answer")
    }

    @discardableResult
    private func raw(_ bytes: Data, wait: Double = 0.3) -> (Data, Net.End)? {
        guard let fd = Net.connect(hookPort) else { return nil }
        defer { close(fd) }
        Net.send(fd, bytes)
        return Net.read(fd, timeout: wait)
    }

    private func abuse() {
        section("Abuse")
        raw(Data((0..<65_536).map { _ in UInt8.random(in: 0...255) }))
        healthy("64 KB of random bytes")
        raw(Data("\r\n\r\n\r\nGET\r\n\r\n \r\n\r\n".utf8))
        healthy("blank and broken request lines")
        raw(Data("POST /claude/permission HTTP/1.1\r\nContent-Length: 1000000000000\r\n\r\n{}".utf8))
        healthy("a Content-Length of a terabyte")
        raw(Data("POST /claude/permission HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n{}".utf8))
        healthy("a Content-Length too big for an integer")
        let header = "POST /claude/permission HTTP/1.1\r\nContent-Length: \(6 << 20)\r\n\r\n"
        let cut = raw(Data(header.utf8) + Data(repeating: 0x7B, count: 6 << 20), wait: 3)
        check(cut?.1 == .eof || cut?.1 == .reset, "a 6 MB body is cut off")
        healthy("a 6 MB body")
        raw(Data(repeating: 0x41, count: 1 << 20) + Data(String(repeating: "X-Junk: aaaaaaaa\r\n", count: 60_000).utf8), wait: 0.5)
        healthy("a megabyte request line and a megabyte of headers")

        // Stalled clients. The server answers what it can, refuses the rest at once,
        // and cuts a connection that hasn't sent its request after its deadline.
        let slow = (0..<40).compactMap { _ in Net.connect(hookPort) }
        let opened = Date()
        for fd in slow { Net.send(fd, Data("POST /claude/permission HTTP/1.1\r\nHost: x\r\n".utf8)) }
        let drip = Pending { for _ in 0..<25 { for fd in slow { Net.send(fd, Data("X".utf8)) }; pause(0.1) } }
        let during = probe(5)
        _ = drip.wait(10)
        check(slow.count == 40 && during.slowest < 1, "40 slowloris connections: every real request is answered or refused at once, none hangs",
              "\(during.answered) answered, \(during.refused) refused, slowest \(secs(during.slowest))")
        let slowCut = cutOff(slow, since: opened)
        check(slowCut.count == 40 && slowCut.last < 13, "…and the server cuts every stalled connection", "all closed within \(secs(slowCut.last))")
        slow.forEach { close($0) }
        healthy("slowloris")

        let idle = (0..<200).compactMap { _ in Net.connect(hookPort, timeout: 5) }
        let idleSince = Date()
        let meanwhile = probe(3)
        check(idle.count == 200 && meanwhile.slowest < 1, "200 idle connections: real requests are answered or refused at once",
              "\(meanwhile.answered) answered, \(meanwhile.refused) refused")
        let idleCut = cutOff(idle, since: idleSince)
        check(idleCut.count == 200 && idleCut.last < 13, "…and the idle ones are cut off", "all closed within \(secs(idleCut.last))")
        idle.forEach { close($0) }
        healthy("200 idle connections")

        // A burst of real requests at once: each is held or refused, none is left hanging.
        let flood = (0..<200).map { _ in "flood-" + UUID().uuidString.lowercased() }
        let h = hooked!
        var conns: [Int32] = []
        for sid in flood {
            var payload = h.permissionPayload(command: "echo \(sid)", suggestions: suggestions)
            payload["session_id"] = sid
            let body = json(payload)
            guard let fd = Net.connect(hookPort, timeout: 5) else { continue }
            var head = "POST \(permissionURL.path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            for (k, v) in claudeHeaders { head += "\(k): \(v)\r\n" }
            head += "Content-Length: \(body.count)\r\n\r\n"
            Net.send(fd, Data(head.utf8) + body)
            conns.append(fd)
        }
        var held = -1
        for _ in 0..<40 {
            pause(0.25)
            let now = app.state()?.prompts.filter { ($0["sid"] as? String)?.hasPrefix("flood-") == true }.count ?? -1
            if now == held { break }
            held = now
        }
        for p in app.state()?.prompts ?? [] where (p["sid"] as? String)?.hasPrefix("flood-") == true { answer(p, "deny") }
        var denied = 0, refused = 0, hung = 0
        for fd in conns {
            let (data, end) = Net.read(fd, timeout: 5)
            if let r = HTTP.parse(data, elapsed: 0), sameJSON(r.body, Expect.deny) { denied += 1 } else if data.isEmpty, end != .timeout { refused += 1 } else { hung += 1 }
            close(fd)
        }
        check(conns.count == 200 && held > 0 && denied == held && denied + refused == 200 && hung == 0,
              "200 hook requests at once: each is held and answered, or refused at once; none hangs",
              "\(held) held and denied, \(refused) refused")
        expect(app, "…and their rows go", within: 5) { !$0.ids.contains { $0.hasPrefix("claude:flood-") } }
        healthy("200 concurrent requests")

        raw(Data("POST /claude/permission HTTP/1.1\r\nX-Muster-Token: wrong\r\nContent-Length: -5\r\n\r\n{}".utf8))
        healthy("a negative Content-Length")
    }

    /// Real (wrong-token) requests: how many were answered, how many refused, and the slowest.
    private func probe(_ n: Int) -> (answered: Int, refused: Int, slowest: Double) {
        var answered = 0, refused = 0, slowest = 0.0
        for _ in 0..<n {
            let start = Date()
            let r = HTTP.request(hookPort, "POST", "/claude/permission", headers: ["X-Muster-Token": "wrong"], body: Data("{}".utf8), timeout: 3)
            if r?.isEmpty200 == true { answered += 1 } else { refused += 1 }
            slowest = max(slowest, Date().timeIntervalSince(start))
            pause(0.3)
        }
        return (answered, refused, slowest)
    }

    /// Waits for the server to close each connection: how many it closed, and when the last went.
    private func cutOff(_ fds: [Int32], since: Date) -> (count: Int, last: Double) {
        var count = 0, last = 0.0
        for fd in fds {
            let (_, end) = Net.read(fd, timeout: max(0.1, 14 - Date().timeIntervalSince(since)))
            guard end != .timeout else { continue }
            count += 1
            last = max(last, Date().timeIntervalSince(since))
        }
        return (count, last)
    }
}
