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

print("Pricing")
check(Pricing.price(for: "claude-haiku-4-5-20251001") != nil, "dated model ids resolve by prefix")
check(Pricing.price(for: "some-new-model") == nil, "unknown models are not priced")

try? fm.removeItem(atPath: root)
print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
