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
var serverPort: UInt16 = 0
let listening = DispatchSemaphore(value: 0)
server.onReady = { serverPort = $0; listening.signal() }
server.onRequest = { r, x in
    if r.path == "/hold" { held.append(x) } else { x.reply(Data(#"{"ok":true}"#.utf8)) }
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

try? fm.removeItem(atPath: root)
print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
