import Foundation
import SQLite3

// Reader tests against fixture files in a temporary home folder.
// Run: ./test.sh

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
let cursor = Dictionary(uniqueKeysWithValues: CursorReader(home: root).scan(now: now).map { ($0.sid, $0) })
check(cursor["c1"]?.status == .needsYou && cursor["c1"]?.project == "/work/web", "a blocking pending action reads as needs you")
check(cursor["c2"]?.status == .done && cursor["c2"]?.title == "Add dark mode", "a turn_ended transcript reads as done, titled by its first query")

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

try? fm.removeItem(atPath: root)
print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
