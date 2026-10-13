import Foundation
import SQLite3

// Reader tests against fixture files in a temporary home folder.
// Run: ./test.sh

setlinebuf(stdout)   // so a crash still shows the checks before it
var failures = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { print("  ✓ \(what)") } else { failures += 1; print("  ✗ \(what)  (\((file as NSString).lastPathComponent):\(line))") }
}

let root = NSTemporaryDirectory() + "muster-tests-\(UUID().uuidString)"
let fm = FileManager.default
func write(_ path: String, _ text: String) {
    try! fm.createDirectory(atPath: (root + path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: root + path, atomically: true, encoding: .utf8)
}
func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
func sqlite(_ path: String, _ statements: [String]) {
    try! fm.createDirectory(atPath: (root + path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var db: OpaquePointer?
    sqlite3_open(root + path, &db)
    for s in statements { sqlite3_exec(db, s, nil, nil, nil) }
    sqlite3_close(db)
}
let now = Date()

func assistant(_ id: String, _ model: String, usage: [String: Any], stop: String = "end_turn", text: String = "ok", ago: Double = 5) -> String {
    json(["type": "assistant", "timestamp": iso(now.addingTimeInterval(-ago)), "cwd": "/work/atlas",
          "message": ["id": id, "model": model, "stop_reason": stop, "content": [["type": "text", "text": text]], "usage": usage]])
}

print("Claude")
let u1: [String: Any] = ["input_tokens": 10, "cache_creation_input_tokens": 300, "cache_read_input_tokens": 1000, "output_tokens": 50,
                         "cache_creation": ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 200]]
let u2: [String: Any] = ["input_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 2000, "output_tokens": 20,
                         "iterations": [["input_tokens": 999_999, "output_tokens": 999_999]]]
write("/.claude/projects/-work-atlas/done.jsonl", [
    json(["type": "custom-title", "customTitle": "Ship passkeys"]),
    assistant("msg_A", "claude-opus-5-5", usage: u1, ago: 9),
    assistant("msg_A", "claude-opus-5-5", usage: u1, ago: 9),
    assistant("msg_B", "claude-opus-5-5", usage: u2, text: #"pasted: "usage": {"input_tokens": 5000000}"#),
].joined(separator: "\n") + "\n")
write("/.claude/projects/-work-atlas/busy.jsonl", json(["type": "assistant", "timestamp": iso(now), "cwd": "/work/atlas",
    "message": ["id": "msg_C", "model": "claude-sonnet-5", "stop_reason": "tool_use",
                "content": [["type": "tool_use", "name": "Bash"]], "usage": ["input_tokens": 1, "output_tokens": 1]]]) + "\n")
write("/.claude/projects/-work-atlas/ask.jsonl", json(["type": "assistant", "timestamp": iso(now), "cwd": "/work/atlas",
    "message": ["id": "msg_D", "stop_reason": "tool_use", "content": [["type": "tool_use", "name": "AskUserQuestion"]]]]) + "\n")
write("/Library/Application Support/Claude/claude-code-sessions/a/b/local_done.json", json([
    "cliSessionId": "done", "sessionId": "local_done", "title": "Passkeys rollout", "isArchived": false,
    "lastActivityAt": now.timeIntervalSince1970 * 1000, "permissionMode": "bypassPermissions",
    "remoteMcpServersConfig": ["blob": String(repeating: "x", count: 1_000_000)]]))

let claude = Dictionary(uniqueKeysWithValues: ClaudeReader(home: root).scan(now: now).map { ($0.sid, $0) })
check(claude["done"]?.status == .done, "a finished turn reads as done")
check(claude["busy"]?.status == .working, "a pending tool call reads as working")
check(claude["ask"]?.status == .needsYou, "AskUserQuestion reads as needs you")
check(claude["done"]?.title == "Passkeys rollout", "Claude.app's sidebar title wins over the transcript's")
check(claude["done"]?.appID == "local_done", "the app id (local_…) is used for deep links")
check(claude["done"]?.tokens == 1360 + 2021, "each message is counted once; escaped and nested usage is ignored")
let opusInput: Double = (10 + 1) * 4.0
let opusOutput: Double = (50 + 20) * 20.0
let opusWrites: Double = 100 * 5.0 + 200 * 8.0
let opusReads: Double = (1000 + 2000) * 0.2
let expected: Double = (opusInput + opusOutput + opusWrites + opusReads) / 1_000_000
check(abs((claude["done"]?.cost ?? 0) - expected) < 1e-12, "cost prices 5-minute and 1-hour cache writes separately")

print("Errors")
func apiError(_ code: String, _ text: String) -> String {
    json(["type": "assistant", "timestamp": iso(now), "cwd": "/work/atlas", "isApiErrorMessage": true, "error": code,
          "message": ["id": UUID().uuidString, "model": "<synthetic>", "stop_reason": "stop_sequence",
                      "content": [["type": "text", "text": text]], "usage": ["input_tokens": 0, "output_tokens": 0]]]) + "\n"
}
write("/.claude/projects/-work-atlas/limit.jsonl", apiError("rate_limit", "You've hit your session limit · resets 6pm (Europe/Madrid)"))
write("/.claude/projects/-work-atlas/offline.jsonl", apiError("server_error", "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)"))
write("/.claude/projects/-work-atlas/busy-api.jsonl", apiError("server_error", "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment."))
write("/.claude/projects/-work-atlas/image.jsonl", apiError("invalid_request", "An image in the conversation exceeds the dimension limit for many-image requests (2000px)."))
write("/.claude/projects/-work-atlas/weekly.jsonl", assistant("msg_W", "claude-opus-5-5", usage: u2, ago: 60))
write("/Library/Application Support/Claude/claude-code-sessions/a/b/local_weekly.json", json([
    "cliSessionId": "weekly", "sessionId": "local_weekly", "title": "Gilvus", "isArchived": false,
    "lastActivityAt": now.timeIntervalSince1970 * 1000, "permissionMode": "default",
    "error": "You've hit your weekly limit · resets Oct 15, 12pm (Europe/Madrid)", "errorAt": now.timeIntervalSince1970 * 1000]))
let errors = Dictionary(uniqueKeysWithValues: ClaudeReader(home: root).scan(now: now).map { ($0.sid, $0) })
check(errors["limit"]?.status == .blocked && errors["limit"]?.stateLabel == "Out of usage", "a session limit stops the session without asking for you")
check(errors["limit"]?.fault?.resets == "6pm", "the reset time is read from the message, without the time zone")
check(errors["limit"]?.status.section == .recent && Status.blocked > .done, "out-of-usage sessions sort below finished ones")
check(errors["weekly"]?.status == .blocked && errors["weekly"]?.fault?.resets == "Oct 15, 12pm", "Claude.app's own limit error stops the session too")
check(errors["offline"]?.status == .error && errors["offline"]?.stateLabel == "Connection lost", "a network failure needs a retry in the session")
check(errors["busy-api"]?.status == .error && errors["busy-api"]?.stateLabel == "API error", "an overloaded API needs a retry in the session")
check(errors["image"]?.status == .error && errors["image"]?.fault?.kind == .other, "a refused request is an error, though its message says limit")
check(Fault(message: "Login expired · Please run /login")?.kind == .signedOut, "an expired login reads as signed out")
check(Fault(message: "Bad Request This model does not support custom API keys.")?.kind == .other, "an API key setting is not a sign-in problem")
check(Fault(message: "You've hit your monthly spend limit · raise it at claude.ai/settings/usage")?.resets == nil, "a spend limit has no reset time")

print("Codex")
let rollout = "/.codex/sessions/2026/10/12/rollout-x.jsonl"
write(rollout, [
    json(["type": "turn_context", "payload": ["model": "gpt-6-astra"]]),
    json(["type": "event_msg", "timestamp": iso(now.addingTimeInterval(-30)), "payload": ["type": "task_started"]]),
    json(["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": [
        "input_tokens": 10_000, "cached_input_tokens": 8_000, "cache_write_input_tokens": 1_000, "output_tokens": 500, "total_tokens": 10_500]]]]),
    json(["type": "event_msg", "timestamp": iso(now.addingTimeInterval(-10)), "payload": ["type": "task_complete"]]),
].joined(separator: "\n") + "\n")
sqlite("/.codex/state_5.sqlite", [
    "CREATE TABLE threads (id TEXT, rollout_path TEXT, name TEXT, title TEXT, first_user_message TEXT, cwd TEXT, archived INT, updated_at_ms INT)",
    "INSERT INTO threads VALUES ('t1', '\(root + rollout)', '', 'Port the parser', '', '/work/lexer', 0, \(Int64(now.timeIntervalSince1970 * 1000)))",
])
let codex = CodexReader(home: root).scan(now: now)
check(codex.first?.status == .done && codex.first?.title == "Port the parser", "a completed task reads as done with its thread title")
check(codex.first?.tokens == 10_500, "tokens come from the running token_count total")
let astraInput: Double = 1_000 * 10.0
let astraWrites: Double = 1_000 * 12.5
let astraReads: Double = 8_000 * 1.0
let astraOutput: Double = 500 * 50.0
let astra: Double = (astraInput + astraWrites + astraReads + astraOutput) / 1_000_000
check(abs((codex.first?.cost ?? 0) - astra) < 1e-12,
      "cost splits fresh input, cache writes and cached input")

print("Cursor")
let header = json(["name": "Polish onboarding", "hasBlockingPendingActions": true,
                   "lastUpdatedAt": now.timeIntervalSince1970 * 1000, "workspaceIdentifier": ["uri": ["fsPath": "/work/web"]]])
sqlite("/Library/Application Support/Cursor/User/globalStorage/state.vscdb", [
    "CREATE TABLE composerHeaders (composerId TEXT, value TEXT, isSubagent INT, isArchived INT, lastUpdatedAt INT, checkpointAt INT)",
    "INSERT INTO composerHeaders VALUES ('c1', '\(header.replacingOccurrences(of: "'", with: "''"))', 0, 0, \(Int64(now.timeIntervalSince1970 * 1000)), NULL)",
])
write("/.cursor/projects/work-web/agent-transcripts/c2/c2.jsonl", [
    json(["message": ["content": [["text": "<user_query>Add dark mode</user_query>"]]]]),
    json(["type": "turn_ended", "status": "success"]),
].joined(separator: "\n") + "\n")
write("/.cursor/projects/work-web/agent-transcripts/c3/c3.jsonl", json(["type": "turn_ended", "status": "error", "error": "User aborted request"]) + "\n")
write("/.cursor/projects/work-web/agent-transcripts/c4/c4.jsonl", json(["type": "turn_ended", "status": "error",
    "error": "API usage limit reached Switched to composer-2.5 after reaching API limit."]) + "\n")
write("/.cursor/projects/work-web/agent-transcripts/c5/c5.jsonl", json(["type": "turn_ended", "status": "error",
    "error": "[unavailable] getaddrinfo ENOTFOUND agentn.api5.cursor.sh"]) + "\n")
let cursor = Dictionary(uniqueKeysWithValues: CursorReader(home: root).scan(now: now).map { ($0.sid, $0) })
check(cursor["c1"]?.status == .needsYou && cursor["c1"]?.project == "/work/web", "a blocking pending action reads as needs you")
check(cursor["c2"]?.status == .done && cursor["c2"]?.title == "Add dark mode", "a turn_ended transcript reads as done, titled by its first query")
check(cursor["c3"]?.status == .done && cursor["c3"]?.fault == nil, "a turn you cancelled reads as done, not an error")
check(cursor["c4"]?.status == .blocked, "Cursor's usage limit stops the session without asking for you")
check(cursor["c5"]?.status == .error && cursor["c5"]?.stateLabel == "Connection lost", "Cursor's network failure needs a retry")

print("Usage history")
let midnight = Calendar.current.startOfDay(for: now)
let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func message(_ id: String, _ at: Date, _ usage: [String: Any], model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
    json(["type": "assistant", "timestamp": isoFrac.string(from: at), "cwd": "/work/atlas", "isSidechain": sidechain,
          "message": ["id": id, "model": model, "usage": usage, "content": [["type": "tool_use", "name": "Bash",
                      "input": ["cwd": "/elsewhere", "timestamp": "2020-01-01T00:00:00Z"]]]]])
}
let small: [String: Any] = ["input_tokens": 5, "output_tokens": 5]
let h1 = message("msg_H1", midnight.addingTimeInterval(-30), u1)
write("/history/.claude/projects/-work-atlas/a.jsonl", [h1, h1, message("msg_H2", midnight.addingTimeInterval(30), u2)].joined(separator: "\n") + "\n")
write("/history/.claude/projects/-work-atlas/b.jsonl", h1 + "\n")
write("/history/.claude/projects/-work-atlas/a/subagents/agent-1.jsonl",
      message("msg_H3", midnight.addingTimeInterval(60), small, model: "claude-sonnet-5", sidechain: true) + "\n")
write("/history/.claude/projects/-work-old/old.jsonl", message("msg_H9", now.addingTimeInterval(-3600), small) + "\n")
try! fm.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: root + "/history/.claude/projects/-work-old/old.jsonl")
let rollout2 = "/history/.codex/sessions/rollout-y.jsonl"
func tokenCount(_ at: Date, _ input: Int, _ cached: Int, _ write: Int, _ output: Int) -> String {
    json(["timestamp": isoFrac.string(from: at), "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": [
        "input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": write, "output_tokens": output]]]])
}
write(rollout2, [
    json(["timestamp": isoFrac.string(from: midnight.addingTimeInterval(-7200)), "type": "turn_context", "payload": ["model": "gpt-6-astra"]]),
    tokenCount(midnight.addingTimeInterval(-3600), 10_000, 8_000, 1_000, 500),
    tokenCount(midnight.addingTimeInterval(3600), 16_000, 12_000, 1_000, 900),
].joined(separator: "\n") + "\n")
sqlite("/history/.codex/state_5.sqlite", [
    "CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, archived INT, updated_at_ms INT)",
    "INSERT INTO threads VALUES ('t2', '\(root + rollout2)', '/work/lexer', 0, \(Int64(now.timeIntervalSince1970 * 1000)))",
])
let cachePath = root + "/history/usage-cache.bin"
let history = History(home: root + "/history", configDir: nil, codexHome: nil, cachePath: cachePath)
let first = history.scan(now: now)!
let yesterday = first.days[History.days - 2], today = first.days[History.days - 1]
check(first.days.count == 30 && today.start == midnight, "thirty local days, ending today")
check(yesterday.tokens[.claude] == 1360 && today.tokens[.claude] == 2021 + 10,
      "Claude messages count on their local day either side of midnight, subagents included")
check(first.models.first { $0.name == "claude-opus-5-5" }?.tokens == 1360 + 2021,
      "a message repeated in its file and copied into a resumed session counts once")
let h1Writes: Double = 100 * 5.0 + 200 * 8.0
let h1Rest: Double = 10 * 4.0 + 50 * 20.0 + 1000 * 0.2
let h1Cost: Double = (h1Writes + h1Rest) / 1_000_000
check(abs((yesterday.cost[.claude] ?? 0) - h1Cost) < 1e-12, "1-hour cache writes are priced apart from 5-minute ones")
check(first.projects.first { $0.id == "/work/atlas" }?.name == "atlas", "projects come from the top-level cwd, not tool input")
check(yesterday.tokens[.codex] == 10_500 && today.tokens[.codex] == 6_400, "each Codex token_count adds its change to its own day")
let deltaCost: Double = (2_000 * 10.0 + 4_000 * 1.0 + 400 * 50.0) / 1_000_000
check(abs((today.cost[.codex] ?? 0) - deltaCost) < 1e-12 && first.models.contains { $0.name == "gpt-6-astra" && $0.agent == .codex }, "Codex deltas are priced under the turn's model")
check(history.stats.files == 4 && first.tokens == 1360 + 2031 + 16_900, "files untouched for over 30 days are skipped")
check(history.stats.parsed == 4 && history.stats.cached == 0, "a first scan reads every file")
let second = history.scan(now: now)!
check(history.stats.cached == 4 && history.stats.bytesRead == 0 && second.tokens == first.tokens,
      "a second scan reads nothing from unchanged files")
let appended = message("msg_H4", midnight.addingTimeInterval(90), small) + "\n"
let handle = FileHandle(forWritingAtPath: root + "/history/.claude/projects/-work-atlas/a.jsonl")!
handle.seekToEndOfFile()
handle.write(appended.data(using: .utf8)!)
try! handle.close()
let third = history.scan(now: now)!
check(history.stats.appended == 1 && history.stats.bytesRead == UInt64(appended.utf8.count)
      && third.days[History.days - 1].tokens[.claude] == 2031 + 10, "a grown transcript is read from where the last scan stopped")
check(UsageHistory.sample(now: now).tokens == UsageHistory.sample(now: now).tokens && UsageHistory.sample(now: now).tokens > 0,
      "demo history is the same every time")

print("Claude billing")
let live = "/live/.claude/projects/-work-atlas"
func said(_ id: String, _ session: String, _ ago: Double, _ usage: [String: Any], sidechain: Bool = false,
          stop: String = "end_turn", tool: String? = nil) -> String {
    let content: [[String: Any]] = tool.map { [["type": "tool_use", "name": $0, "input": ["command": "ls"]]] } ?? [["type": "text", "text": "ok"]]
    return json(["type": "assistant", "sessionId": session, "timestamp": isoFrac.string(from: now.addingTimeInterval(-ago)),
                 "cwd": "/work/atlas", "isSidechain": sidechain,
                 "message": ["id": id, "model": "claude-opus-5-5", "stop_reason": stop, "content": content, "usage": usage]])
}
// Claude.app writes a message to the old transcript and to the one it compacted into.
write(live + "/early.jsonl", [said("msg_E1", "early", 600, small), said("msg_S", "early", 300, u1)].joined(separator: "\n") + "\n")
write(live + "/late.jsonl", [said("msg_S", "late", 300, u1), said("msg_L1", "late", 60, u2)].joined(separator: "\n") + "\n")
// A resumed session starts with a copy of the history it continues.
write(live + "/resumed.jsonl", [said("msg_E1", "early", 600, small), said("msg_R1", "resumed", 30, small)].joined(separator: "\n") + "\n")
// Subagents: beside the session, nested in a workflow, and in the older top-level layout (copied into a second project).
write(live + "/early/subagents/agent-s1.jsonl", said("msg_S1", "early", 200, small, sidechain: true) + "\n")
write(live + "/early/subagents/workflows/wf_1/agent-w1.jsonl", said("msg_W1", "early", 200, small, sidechain: true) + "\n")
write(live + "/agent-t1.jsonl", said("msg_T1", "early", 200, small, sidechain: true) + "\n")
write("/live/.claude/projects/-work-other/agent-t1.jsonl", said("msg_T1", "early", 200, small, sidechain: true) + "\n")
let billing = Dictionary(uniqueKeysWithValues: ClaudeReader(home: root + "/live").scan(now: now).map { ($0.sid, $0) })
check(billing["early"]?.tokens == 10 + 1360 + 10 + 10 + 10 && billing["late"]?.tokens == 2021,
      "a message two sessions both wrote bills once, to the session that started first")
check(billing["resumed"]?.tokens == 10, "a resumed session doesn't bill the history it copied")
check(billing.values.reduce(0) { $0 + $1.tokens } == 10 + 1360 + 2021 + 10 + 10 + 10 + 10,
      "subagents, nested workflow agents and top-level agent files bill to their session, once")
check(billing.keys.allSatisfy { !$0.hasPrefix("agent-") }, "agent transcripts never show as sessions")
for order in [["late", "early"], ["early", "late"]] {
    let tally = UsageTally()
    tally.begin()
    for sid in order { tally.add(stat(root + live + "/\(sid).jsonl")!, session: sid) }
    tally.end()
    check(tally.usage(of: "early").values.reduce(0) { $0 + $1.total } == 1370 && tally.usage(of: "late").values.reduce(0) { $0 + $1.total } == 2021,
          "the earlier session keeps the message whichever file is read first (\(order[0]) first)")
}

print("Incremental reads")
let grow = root + live + "/grow.jsonl"
let streaming: [String: Any] = ["input_tokens": 1, "cache_read_input_tokens": 2000, "output_tokens": 5]
let finished: [String: Any] = ["input_tokens": 1, "cache_read_input_tokens": 2000, "output_tokens": 20]
let last = said("msg_G2", "grow", 2, finished)
write(live + "/grow.jsonl", [said("msg_G1", "grow", 20, small, stop: "tool_use", tool: "Bash"),
                             said("msg_G2", "grow", 2, streaming, stop: "")].joined(separator: "\n") + "\n" + last.prefix(last.count / 2))
let reader = ClaudeReader(home: root + "/live")
func session(_ sid: String, _ changes: Changes = .all) -> Session? { reader.scan(now: now, changes: changes).first { $0.sid == sid } }
let half = session("grow")
check(half?.status == .working && half?.tokens == 10 + 2006, "a line still being written is left for the next scan")
func append(_ path: String, _ text: String) {
    let h = FileHandle(forWritingAtPath: path)!
    h.seekToEndOfFile()
    h.write(text.data(using: .utf8)!)
    try! h.close()
}
append(grow, String(last.dropFirst(last.count / 2)) + "\n")
let completed = session("grow")
check(completed?.status == .done && completed?.tokens == 10 + 2021, "once finished, it updates the status and the message's usage, counted once")
append(grow, said("msg_G3", "grow", 1, small, stop: "tool_use", tool: "Bash") + "\n")
check(session("grow", Changes())?.tokens == 10 + 2021, "a scan told nothing changed reads nothing")
var named = Changes()
named.add(canonical(root + live) + "/")
let told = session("grow", named)
check(told?.tokens == 10 + 2021 + 10 && told?.status == .working, "a scan reads the directories FSEvents named")
let h2 = FileHandle(forWritingAtPath: grow)!
try! h2.truncate(atOffset: 0)
h2.write((said("msg_G4", "grow", 1, u2) + "\n").data(using: .utf8)!)
try! h2.close()
let truncated = session("grow")
check(truncated?.tokens == 2021 && truncated?.status == .done, "a truncated transcript is read again from the start")
let h3 = FileHandle(forWritingAtPath: grow)!
try! h3.truncate(atOffset: 0)
h3.write(((1...6).map { said("msg_P\($0)", "grow", 1, small) }.joined(separator: "\n") + "\n").data(using: .utf8)!)
try! h3.close()
check(session("grow")?.tokens == 60, "a transcript rewritten in place to a larger size is read again from the start")
write(live + "/grow.jsonl", said("msg_G5", "grow", 1, small, stop: "tool_use", tool: "Read") + "\n")
let replaced = session("grow")
check(replaced?.tokens == 10 && replaced?.status == .working, "a replaced transcript is read again from the start")

// A tool result too big to load (12 MB > the 8 MB a line may take), keys in Claude Code's order.
func giant(_ session: String) -> String {
    "{\"parentUuid\":null,\"isSidechain\":false,\"cwd\":\"/work/atlas\",\"sessionId\":\"\(session)\",\"type\":\"user\"," +
    "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"" + String(repeating: "a", count: 12 << 20) +
    "\"}]},\"timestamp\":\"\(isoFrac.string(from: now))\"}\n"
}
let huge = root + live + "/huge.jsonl"
write(live + "/huge.jsonl", said("msg_B1", "huge", 30, small, stop: "tool_use", tool: "Bash") + "\n" + giant("huge"))
let hugeReader = ClaudeReader(home: root + "/live")
let hugeFirst = hugeReader.scan(now: now).first { $0.sid == "huge" }
check(hugeFirst?.status == .working && hugeFirst?.tokens == 10, "a giant tool result as the newest line keeps the session, working")
append(huge, said("msg_B2", "huge", 1, small) + "\n")
check(hugeReader.scan(now: now).first { $0.sid == "huge" }?.status == .done, "…and the reply after it reads as done")
append(huge, giant("huge"))
let hugeAgain = hugeReader.scan(now: now).first { $0.sid == "huge" }
check(hugeAgain?.status == .working && hugeAgain?.tokens == 20, "a giant line appended later reads as working, without being loaded")

let codexReader = CodexReader(home: root)
_ = codexReader.scan(now: now)
append(root + rollout, json(["type": "event_msg", "timestamp": iso(now), "payload": ["type": "task_started"]]) + "\n"
       + json(["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": [
           "input_tokens": 12_000, "cached_input_tokens": 8_000, "cache_write_input_tokens": 1_000, "output_tokens": 700]]]]) + "\n")
let resumedCodex = codexReader.scan(now: now).first
check(resumedCodex?.status == .working && resumedCodex?.tokens == 12_700, "Codex reads only what was appended: a new turn and its running total")
let cursorReader = CursorReader(home: root)
_ = cursorReader.scan(now: now)
append(root + "/.cursor/projects/work-web/agent-transcripts/c2/c2.jsonl", json(["message": ["content": [["text": "And light mode"]]]]) + "\n")
let reopened = cursorReader.scan(now: now).first { $0.sid == "c2" }
check(reopened?.status == .working && reopened?.title == "Add dark mode", "a Cursor chat that continues reads as working, keeping its title")

// What FSEvents does and doesn't report: a folder's permission change goes to its
// parent, a watched folder's own change goes nowhere, and Codex's rollout paths
// needn't be spelled the way FSEvents spells them (/var vs /private/var here).
append(root + rollout, json(["type": "event_msg", "timestamp": iso(now), "payload": ["type": "task_complete"]]) + "\n")
check(codexReader.scan(now: now, changes: Changes()).first?.status == .done, "a Codex rollout is checked every scan, whatever its path's spelling")
func named(_ dir: String) -> Changes { var c = Changes(); c.add(canonical(dir)); return c }
let projects = root + "/live/.claude/projects"
chmod(root + live, 0o000)
let lockedProject = reader.scan(now: now, changes: named(projects))
chmod(root + live, 0o755)
check(!lockedProject.contains { $0.sid == "early" }, "an unreadable project folder drops its sessions")
check(reader.scan(now: now, changes: named(projects)).contains { $0.sid == "early" }, "…which come back once it's readable")
chmod(root + "/.codex/state_5.sqlite", 0o000)
_ = codexReader.scan(now: now, changes: named(root + "/.codex"))
let lockedDB = codexReader.state
chmod(root + "/.codex/state_5.sqlite", 0o644)
check({ if case .unreadable = lockedDB { return true } else { return false } }(), "an unreadable Codex database shows as unreadable, open connection or not")
_ = codexReader.scan(now: now, changes: named(root + "/.codex"))
check(codexReader.state == .ok(1), "…and recovers")
chmod(root + "/.cursor/projects", 0o000)
let lockedCursor = cursorReader.scan(now: now, changes: Changes())
chmod(root + "/.cursor/projects", 0o755)
check(!lockedCursor.contains { $0.sid == "c2" }, "an unreadable Cursor projects folder drops its file-only chats, though FSEvents says nothing")
check(cursorReader.scan(now: now, changes: Changes()).contains { $0.sid == "c2" }, "…which come back")

print("Pricing")
check(Pricing.price(for: "claude-haiku-4-5-20251001") != nil, "dated model ids resolve by prefix")
check(Pricing.price(for: "some-new-model") == nil, "unknown models are not priced")

print("Stats")
let suite = "muster-tests-\(UUID().uuidString)"
Stats.store = UserDefaults(suiteName: suite)!
var monday = DateComponents(calendar: Calendar(identifier: .iso8601), year: 2026, month: 10, day: 12, hour: 9).date!
Stats.record(.answered, at: monday)
Stats.record(.answered, at: monday.addingTimeInterval(86_400 * 6))
Stats.record(.jumped, at: monday)
check(Stats.week(of: monday).answered == 2 && Stats.week(of: monday).jumps == 1, "Monday to Sunday count as one week")
check(Stats.week(of: monday.addingTimeInterval(86_400 * 7)).answered == 0, "a new week starts at zero")
check(Stats.week(of: monday).saved == 2 * Stats.secondsPerAnswer + Stats.secondsPerJump, "time saved follows the stated assumptions")
check(Stats.summary(Stats.Week(answered: 48, jumps: 132)) == "48 prompts answered without switching  ·  132 jumps  ·  about 23 min saved",
      "the summary reads as counts first, then the estimate")
monday = monday.addingTimeInterval(86_400 * 7 * 13)
Stats.record(.jumped, at: monday)
check((Stats.store.dictionary(forKey: "stats.weeks") ?? [:]).count == 1, "weeks older than twelve are dropped")
UserDefaults.standard.removePersistentDomain(forName: suite)

print("Hook requests")
/// Repeatable random numbers for the fuzzing below (SplitMix64).
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
func parsed(_ s: String) -> HTTPRequest.Parse { HTTPRequest.parse(Data(s.utf8)) }
func complete(_ p: HTTPRequest.Parse) -> HTTPRequest? { if case .complete(let r) = p { return r }; return nil }
func partial(_ p: HTTPRequest.Parse) -> Bool { if case .partial = p { return true }; return false }
func invalid(_ p: HTTPRequest.Parse) -> Bool { if case .invalid = p { return true }; return false }
func post(_ headers: [String], body: String = "{}") -> String {
    (["POST /claude/permission HTTP/1.1"] + headers).joined(separator: "\r\n") + "\r\n\r\n" + body
}

let whole = post(["Host: 127.0.0.1", "X-Muster-Token: abc", "Content-Length: 2"])
let r = complete(parsed(whole))
check(r?.path == "/claude/permission" && r?.headers["x-muster-token"] == "abc" && r?.body == Data("{}".utf8), "a whole request parses")
check((0..<whole.utf8.count).allSatisfy { partial(HTTPRequest.parse(Data(whole.utf8.prefix($0)))) }, "every cut-short request waits for more")
check(complete(HTTPRequest.parse(Data(("junk" + whole).utf8).dropFirst(4)))?.body == Data("{}".utf8), "a slice of a buffer parses")
check(complete(parsed(post(["Content-Length: 2", "Content-Length: 2"]))) != nil, "a repeated, equal Content-Length is fine")
check(invalid(parsed(post(["Content-Length: 2", "Content-Length: 3"], body: "{} "))), "conflicting Content-Lengths are refused")
check(invalid(parsed(post(["Content-Length: 2", "Transfer-Encoding: chunked"]))), "a chunked body is refused")
check(invalid(parsed(post(["Content-Length: 2", "no colon here"]))), "a header without a colon is refused")
check(invalid(parsed(post([": empty name", "Content-Length: 2"]))), "a header without a name is refused")
check(invalid(parsed("GARBAGE\r\n\r\n")) && invalid(parsed("\r\n\r\n")) && invalid(parsed("POST\r\n\r\n")), "a broken request line is refused")
check(complete(parsed(post(["X-Muster-Token: a", "x-muster-token: b", "Content-Length: 2"])))?.headers["x-muster-token"] != "b",
      "a repeated token header can't override the first")
check(invalid(parsed(post(["Host: " + String(repeating: "a", count: HTTPRequest.maxHead)]))), "headers over the cap are refused")
check(invalid(parsed("POST / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.maxHead))),
      "a header line over the cap is refused before it ends")
check(complete(parsed(post(["X: " + String(repeating: "a", count: HTTPRequest.maxHead - 100), "Content-Length: 2"]))) != nil,
      "headers under the cap parse")
check(invalid(parsed(post(["Content-Length: \(HTTPRequest.maxBody + 1)"]))), "a body over 4 MB is refused before it arrives")
for bad in ["-5", "-0", "+2", "2x", "0x2", "2 2", "", "99999999999999999999999", "１２", "\u{0662}"] {
    check(invalid(parsed(post(["Content-Length: \(bad)"]))), "Content-Length \"\(bad)\" is refused")
}

// Random bytes, and random damage to a good request: nothing may trap, and
// whatever parses has exactly the body its Content-Length promised.
var rng = Seeded(state: 20261012)
let alphabet: [[UInt8]] = ["\r\n", "\r\n\r\n", ":", " ", "-", "0", "9", "Content-Length", "Transfer-Encoding", "POST", "/", "\u{0}", "\u{FF}", "é"]
    .map { Array($0.utf8) } + (0..<16).map { _ in [UInt8.random(in: 0...255, using: &rng)] }
var consistent = true
for i in 0..<20_000 {
    var bytes: [UInt8]
    if i % 2 == 0 {
        bytes = (0..<Int.random(in: 0...64, using: &rng)).flatMap { _ in alphabet.randomElement(using: &rng)! }
    } else {
        bytes = Array(whole.utf8)
        for _ in 0..<Int.random(in: 1...4, using: &rng) {
            let at = Int.random(in: 0..<bytes.count, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: bytes[at] = UInt8.random(in: 0...255, using: &rng)
            case 1: bytes.insert(contentsOf: alphabet.randomElement(using: &rng)!, at: at)
            default: bytes.remove(at: at)
            }
            if bytes.isEmpty { bytes = [0] }
        }
    }
    if let req = complete(HTTPRequest.parse(Data(bytes))) {
        let promised = req.headers["content-length"].flatMap { Int($0) } ?? 0
        if req.body.count != promised || promised > HTTPRequest.maxBody { consistent = false }
    }
}
check(consistent, "20,000 fuzzed requests parse without trapping, each with the body it promised")

print("Hook server")
let serverQueue = DispatchQueue(label: "muster-tests.server")
let server = HookServer(ports: 47_700...47_719, queue: serverQueue)
var held: [HookServer.Exchange] = []
var heldClosed = 0
var serverPort: UInt16 = 0
let listening = DispatchSemaphore(value: 0)
server.onReady = { serverPort = $0; listening.signal() }
server.onRequest = { r, x in
    guard r.path == "/hold" else { x.reply(Data(#"{"ok":true}"#.utf8)); return }
    held.append(x)
    x.onClose { heldClosed += 1 }
}
/// Polls the server's state until `cond` holds, for up to `wait` seconds.
func soon(_ wait: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(wait)
    while Date() < end {
        if serverQueue.sync(execute: cond) { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}
serverQueue.sync { server.deadline = 0.5; server.maxIncoming = 3; server.start(on: 47_700) }
check(listening.wait(timeout: .now() + 5) == .success, "the server listens on 127.0.0.1")

/// A plain TCP client, so the tests can misbehave the way a hostile one would.
func dial() -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = serverPort.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return ok == 0 ? fd : -1
}
func send(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
}
/// Everything the server sent once it closed, or nil if it was still open after `wait` seconds.
func closed(_ fd: Int32, wait: Double) -> String? {
    var tv = timeval(tv_sec: Int(wait), tv_usec: Int32((wait - Double(Int(wait))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n > 0 { out.append(contentsOf: buffer[0..<n]); continue }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { return nil }
        return String(decoding: out, as: UTF8.self)
    }
}
let hello = post(["Content-Length: 2"])

var started = Date()
var idle = dial()
check(closed(idle, wait: 3) != nil && Date().timeIntervalSince(started) < 2, "a client that sends nothing is closed at the deadline")
close(idle)
started = Date()
idle = dial()
send(idle, "POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n{")
check(closed(idle, wait: 3) != nil && Date().timeIntervalSince(started) < 2, "a request that never finishes is closed at the deadline")
close(idle)

serverQueue.sync { server.deadline = 30 }
let crowd = (0..<3).map { _ in dial() }
let extra = dial()
check(closed(extra, wait: 2) != nil, "past the cap on half-sent requests, a new connection is turned away")
close(extra)
close(crowd[0])
Thread.sleep(forTimeInterval: 0.3)
let next = dial()
send(next, hello)
check(closed(next, wait: 3)?.hasPrefix("HTTP/1.1 200 OK") == true, "a slot frees up when a half-sent request goes away")
close(next)
crowd.dropFirst().forEach { close($0) }
Thread.sleep(forTimeInterval: 0.3)

serverQueue.sync { server.deadline = 0.5 }
let holder = dial()
send(holder, "POST /hold HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}")
check(closed(holder, wait: 1.5) == nil, "a request held for an answer outlives the deadline")
serverQueue.sync { held.first?.reply(Data(#"{"answer":1}"#.utf8)) }
check(closed(holder, wait: 3)?.hasSuffix(#"{"answer":1}"#) == true, "and gets its answer when it comes")
close(holder)

let holdRequest = "POST /hold HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
var (holds, closes) = serverQueue.sync { (held.count, heldClosed) }
let quitter = dial()
send(quitter, holdRequest)
check(soon(2) { held.count == holds + 1 }, "another request is held")
close(quitter)
check(soon(1) { heldClosed == closes + 1 }, "and withdrawn within a second of the client hanging up")

(holds, closes) = serverQueue.sync { (held.count, heldClosed) }
let chatty = dial()
send(chatty, holdRequest + "POST /x HTTP/1.1\r\nContent-Length: -5\r\n\r\nnoise")
check(soon(2) { held.count == holds + 1 } && closed(chatty, wait: 0.7) == nil && serverQueue.sync { heldClosed } == closes,
      "bytes after a held request are ignored, past the deadline too")
serverQueue.sync { held.last?.reply(Data(#"{"answer":2}"#.utf8)) }
check(closed(chatty, wait: 3)?.hasSuffix(#"{"answer":2}"#) == true, "and the answer still arrives")
close(chatty)

(holds, closes) = serverQueue.sync { (held.count, heldClosed) }
let flood = dial()
send(flood, holdRequest)
check(soon(2) { held.count == holds + 1 }, "a held client that keeps sending…")
var sendWait = timeval(tv_sec: 5, tv_usec: 0)   // a server that stops reading would block this send for good
setsockopt(flood, SOL_SOCKET, SO_SNDTIMEO, &sendWait, socklen_t(MemoryLayout<timeval>.size))
send(flood, String(repeating: "x", count: HTTPRequest.maxHead + HTTPRequest.maxBody + 1))
check(soon(3) { heldClosed == closes + 1 }, "…is cut off once it has sent more than a request could hold")
close(flood)

let hostile = dial()
send(hostile, "POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\n")
check(closed(hostile, wait: 3) == "", "a malformed request is closed without an answer")
close(hostile)
let after = dial()
send(after, hello)
check(closed(after, wait: 3)?.hasPrefix("HTTP/1.1 200 OK") == true, "and the server keeps serving")
close(after)
serverQueue.sync { server.stop() }

print("Whose hooks")
let tokenA = String(repeating: "a", count: 32), tokenB = String(repeating: "b", count: 32), tokenC = String(repeating: "c", count: 32)
func text(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
func object(_ path: String) -> [String: Any] { SettingsFile.read(path) ?? [:] }
func groups(_ path: String, _ event: String) -> [[String: Any]] { (object(path)["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [] }
func userGroup(_ name: String) -> [String: Any] { ["matcher": name, "hooks": [["type": "command", "command": "/usr/bin/true \(name)"]]] }

let shared = root + "/whose/.claude/settings.json"
write("/whose/.claude/settings.json", json(["hooks": ["PermissionRequest": [userGroup("Bash")]]]))
let real = Hooks(agent: .claude, path: shared, port: 47621, token: tokenA)
try! real.install()
let other = Hooks(agent: .claude, path: shared, port: 47623, token: tokenB)
let samePort = Hooks(agent: .claude, path: shared, port: 47621, token: tokenB)
check(real.isInstalled && !other.isInstalled && !samePort.isInstalled, "only the install whose token the hooks carry counts them as its own")
check(!other.isStale, "another build's hooks aren't stale to this one")
if other.isStale { try? other.repoint() }
check(text(shared).contains("47621/claude/permission") && text(shared).contains(tokenA) && !text(shared).contains(tokenB),
      "so a second build on another port leaves the real hooks alone")

let moved = Hooks(agent: .claude, path: shared, port: 47622, token: tokenA)
check(moved.isStale && !moved.isInstalled, "this install's hooks on an earlier port are stale")
let foreign: [String: Any] = ["matcher": "*", "hooks": [["type": "http", "url": "http://127.0.0.1:47630/claude/permission",
                                                          "timeout": 3600, "headers": ["X-Muster-Token": tokenC]]]]
try! SettingsFile.edit(shared) { d in
    var hooks = d["hooks"] as! [String: Any]
    hooks["PermissionRequest"] = (hooks["PermissionRequest"] as! [Any]) + [userGroup("Later"), foreign]
    d["hooks"] = hooks
}
try! moved.repoint()
let order = groups(shared, "PermissionRequest")
check(moved.isInstalled && !moved.isStale && !text(shared).contains("47621"), "repointing moves this install's hooks to the new port")
check(order.count == 4 && (order[0] as NSDictionary) == (userGroup("Bash") as NSDictionary)
      && ((order[1]["hooks"] as? [[String: Any]])?.first?["url"] as? String)?.contains("47622") == true
      && (order[2] as NSDictionary) == (userGroup("Later") as NSDictionary) && (order[3] as NSDictionary) == (foreign as NSDictionary),
      "and leaves every other hook, another build's included, where it was")

let codexShared = root + "/whose/.codex/hooks.json"
let codexReal = Hooks(agent: .codex, path: codexShared, port: 47621, token: tokenA)
try! codexReal.install()
let codexOther = Hooks(agent: .codex, path: codexShared, port: 47623, token: tokenB)
let codexMoved = Hooks(agent: .codex, path: codexShared, port: 47622, token: tokenA)
check(codexReal.isInstalled && !codexOther.isInstalled && !codexOther.isStale && codexMoved.isStale, "the same goes for Codex's hooks")
try! codexMoved.repoint()
check(codexMoved.isInstalled && !text(codexShared).contains("47621"), "and repointing moves Codex's hook too")
try! other.uninstall()
check(!text(shared).contains("X-Muster-Token") && groups(shared, "PermissionRequest").count == 2,
      "turning hooks off removes any Muster's, and only those")

print("Settings edits")
func bytes(_ path: String) -> Data? { fm.contents(atPath: path) }
func mode(_ path: String) -> Int? { (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
func isLink(_ path: String) -> Bool { (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink }
func same(_ path: String, _ expected: [String: Any]) -> Bool { (object(path) as NSDictionary) == (expected as NSDictionary) }
func claudeHooks(_ path: String) -> Hooks { Hooks(agent: .claude, path: path, port: 47621, token: tokenA) }
func failure(_ run: () throws -> Void) -> String? {
    do { try run(); return nil } catch { return error.localizedDescription }
}

let settings: [String: Any] = [
    "model": "opus", "includeCoAuthoredBy": false, "cleanupPeriodDays": 30, "temperature": 0.5,
    "env": ["API_KEY": "sk-not-real", "GREETING": "grüß dich"],
    "permissions": ["allow": ["Bash(ls:*)", "Read(~/notes/**)"], "deny": [String]()],
    "statusLine": ["type": "command", "command": "~/bin/status.sh"],
    "hooks": ["PermissionRequest": [userGroup("Bash")], "Stop": [userGroup("Stop")]],
]
let roundTrip = root + "/edits/round/settings.json"
write("/edits/round/settings.json", json(settings))
try! claudeHooks(roundTrip).install()
check(claudeHooks(roundTrip).isInstalled && same(roundTrip + ".muster-original", settings), "installing keeps a copy of the original")
try! claudeHooks(roundTrip).uninstall()
check(same(roundTrip, settings), "install then uninstall leaves Claude's settings as they were")
check(same(roundTrip + ".muster-original", settings) && (object(roundTrip + ".muster-backup") as NSDictionary) != (settings as NSDictionary)
      && text(roundTrip + ".muster-backup").contains(tokenA),
      "after two edits the original copy is still the original, and .muster-backup is the file before the last edit")
try! claudeHooks(roundTrip).install()
check(same(roundTrip + ".muster-original", settings), "and it stays the original after a third")

let codexOriginal: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": "/usr/bin/true", "timeout": 5]]]]]]
let codexRound = root + "/edits/round/hooks.json"
write("/edits/round/hooks.json", json(codexOriginal))
try! Hooks(agent: .codex, path: codexRound, port: 47621, token: tokenA).install()
try! Hooks(agent: .codex, path: codexRound, port: 47621, token: tokenA).uninstall()
check(same(codexRound, codexOriginal), "install then uninstall leaves Codex's hooks as they were")

let odd = root + "/edits/odd/settings.json"
let oddSettings: [String: Any] = ["hooks": ["PreToolUse": [userGroup("Edit"), "a note"], "Notification": "not a list", "Stop": [String]()]]
write("/edits/odd/settings.json", json(oddSettings))
try! claudeHooks(odd).install()
try! claudeHooks(odd).uninstall()
check(same(odd, oddSettings), "hook entries Muster doesn't understand survive install and uninstall")
let noHooks = root + "/edits/odd/plain.json"
write("/edits/odd/plain.json", json(["model": "opus"]))
try! claudeHooks(noHooks).install()
try! claudeHooks(noHooks).uninstall()
check(same(noHooks, ["model": "opus"]), "settings that had no hooks get none back")
let earlier = root + "/edits/odd/upgraded.json"
write("/edits/odd/upgraded.json.muster-backup", json(settings))
write("/edits/odd/upgraded.json", text(roundTrip))
try! claudeHooks(earlier).uninstall()
check(same(earlier + ".muster-original", settings), "a backup from an earlier version becomes the original copy")

let tidy = root + "/edits/tidy/settings.json"
write("/edits/tidy/settings.json", "{\n    \"zeta\": 1,\n    \"alpha\": [1, 2]\n}\n")
let tidyBefore = bytes(tidy)
try! claudeHooks(tidy).uninstall()
check(bytes(tidy) == tidyBefore && !fm.fileExists(atPath: tidy + ".muster-backup"), "an edit that changes nothing doesn't rewrite the file")
let blank = root + "/edits/tidy/blank.json"
write("/edits/tidy/blank.json", "  \n")
check(failure { try claudeHooks(blank).install() } == nil && claudeHooks(blank).isInstalled, "an empty file counts as no settings yet")

let dotfiles = root + "/edits/dotfiles/claude/settings.json"
write("/edits/dotfiles/claude/settings.json", json(settings))
let linked = root + "/edits/home/.claude/settings.json"
try! fm.createDirectory(atPath: (linked as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! fm.createSymbolicLink(atPath: linked, withDestinationPath: "../../dotfiles/claude/settings.json")
try! claudeHooks(linked).install()
check(isLink(linked) && (try? fm.destinationOfSymbolicLink(atPath: linked)) == "../../dotfiles/claude/settings.json",
      "a symlinked settings file stays a symlink")
check(text(dotfiles).contains(tokenA) && claudeHooks(linked).isInstalled, "and the file it points to gets the hooks")
check(!isLink(linked + ".muster-original") && same(linked + ".muster-original", settings), "the backups beside the link are real copies")
try! claudeHooks(linked).uninstall()
check(isLink(linked) && same(dotfiles, settings), "uninstalling through the link restores the target")
let dangling = root + "/edits/home/.codex/hooks.json"
try! fm.createDirectory(atPath: root + "/edits/dotfiles/codex", withIntermediateDirectories: true)
try! fm.createDirectory(atPath: (dangling as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
try! fm.createSymbolicLink(atPath: dangling, withDestinationPath: root + "/edits/dotfiles/codex/hooks.json")
try! Hooks(agent: .codex, path: dangling, port: 47621, token: tokenA).install()
check(isLink(dangling) && text(root + "/edits/dotfiles/codex/hooks.json").contains(tokenA), "a link to a file not made yet gets that file")

let secret = root + "/edits/private/settings.json"
write("/edits/private/settings.json", json(settings))
chmod(secret, 0o600)
try! claudeHooks(secret).install()
check(mode(secret) == 0o600, "a 0600 settings file stays 0600")
check(mode(secret + ".muster-original") == 0o600 && mode(secret + ".muster-backup") == 0o600, "and so do its backups")
let locked = root + "/edits/private/locked.json"
write("/edits/private/locked.json", json(settings))
chmod(locked, 0o444)
let lockedBefore = bytes(locked)
check(failure { try claudeHooks(locked).install() }?.contains("read-only") == true && bytes(locked) == lockedBefore && mode(locked) == 0o444,
      "a read-only settings file is left alone, with a reason")

let raced = root + "/edits/race/settings.json"
write("/edits/race/settings.json", json(["model": "opus"]))
var passes = 0
try! SettingsFile.edit(raced) { d in
    passes += 1
    if passes == 1 { write("/edits/race/settings.json", json(["model": "opus", "theme": "dark"])) }
    d["muster"] = true
}
check(passes == 2 && same(raced, ["model": "opus", "theme": "dark", "muster": true]),
      "a change the agent writes mid-edit is kept, and the edit is redone on top")
let busy = root + "/edits/race/busy.json"
write("/edits/race/busy.json", json(["n": 0]))
var writes = 0
let busyError = failure {
    try SettingsFile.edit(busy) { d in
        writes += 1
        write("/edits/race/busy.json", json(["n": writes]))
        d["muster"] = true
    }
}
check(busyError?.contains("kept changing") == true && same(busy, ["n": writes]), "a file that never settles is left alone, with a reason")

let broken = root + "/edits/broken/settings.json"
for (name, content) in [("invalid JSON", #"{"model": "opus""#), ("JSON with comments", "{\n  // mine\n  \"model\": \"opus\"\n}"),
                        ("a list at the top", "[1, 2]"), ("hooks that aren't an object", #"{"hooks": [1]}"#),
                        ("an event that isn't a list", #"{"hooks": {"PermissionRequest": {"matcher": "*"}}}"#)] {
    write("/edits/broken/settings.json", content)
    let message = failure { try claudeHooks(broken).install() }
    check(message?.contains("left it alone") == true && text(broken) == content && !fm.fileExists(atPath: broken + ".muster-backup"),
          "\(name) is left untouched, with a reason")
}
let timed = root + "/edits/times/hooks.json"
try! Hooks(agent: .codex, path: timed, port: 47621, token: tokenA).install()
let codexHandler = (groups(timed, "PermissionRequest").first?["hooks"] as? [[String: Any]])?.first ?? [:]
let curlWait = (codexHandler["command"] as? String).flatMap { c in
    c.range(of: "--max-time ").flatMap { Int(c[$0.upperBound...].prefix { $0.isNumber }) }
} ?? .max
check(curlWait <= 600, "if Muster hangs, Codex waits at most 10 minutes for its own prompt")
check((codexHandler["timeout"] as? Int ?? 0) >= curlWait, "Codex's own hook timeout doesn't cut curl short")
check(Hooks.codexHold + Hooks.holdSweep < Double(curlWait), "Muster lets go of a Codex prompt before curl gives up on it")
let timedClaude = root + "/edits/times/settings.json"
try! claudeHooks(timedClaude).install()
check((groups(timedClaude, "PermissionRequest").first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 3600,
      "Claude's hook still waits an hour, beside its own dialog")

let strays = (fm.enumerator(atPath: root + "/edits")?.allObjects as? [String] ?? []).filter {
    let name = ($0 as NSString).lastPathComponent
    return name.hasPrefix(".") && name.contains(".muster-")
}
check(strays.isEmpty, "no half-written files are left behind")

try? fm.removeItem(atPath: root)
print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
