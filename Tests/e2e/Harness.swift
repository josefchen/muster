import Foundation
import SQLite3

// The pieces every e2e mode shares: reporting, raw HTTP over sockets, a fixture
// home with writers for each agent's files, and the app under test.

// MARK: - Reporting

var failures = 0
var passed = 0
var failedChecks: [String] = []

func check(_ ok: Bool, _ what: String, _ note: String = "") {
    let suffix = note.isEmpty ? "" : "  (\(note))"
    if ok {
        passed += 1
        print("  ✓ \(what)\(suffix)")
    } else {
        failures += 1
        failedChecks.append(what)
        print("  ✗ \(what)\(suffix)")
    }
    fflush(stdout)
}

func section(_ title: String) {
    print("\n\(title)")
    fflush(stdout)
}

func note(_ text: String) {
    print("    \(text)")
    fflush(stdout)
}

func fatal(_ why: String) -> Never {
    print("e2e: \(why)")
    fflush(stdout)
    exit(2)   // the atexit handler stops the app and removes the fixtures
}

/// The run's temp folder: $TMPDIR as scripts/e2e.sh sets it, which NSTemporaryDirectory ignores.
let tempRoot: String = {
    let t = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: t).resolvingSymlinksInPath().path
}()

func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

func secs(_ t: Double) -> String { String(format: "%.2f s", t) }

func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

// MARK: - JSON

func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data() }

func jsonLine(_ o: [String: Any]) -> Data { json(o) + Data([0x0A]) }

func parseJSON(_ d: Data) -> Any? { d.isEmpty ? nil : try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) }

/// Structural equality, the way the agents read the reply.
func sameJSON(_ data: Data?, _ expected: Any) -> Bool {
    guard let data, let got = parseJSON(data) else { return false }
    return (got as AnyObject).isEqual(expected)
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

func hex(_ n: Int) -> String { (0..<n).map { _ in String("0123456789abcdef".randomElement()!) }.joined() }

// MARK: - Sockets

enum Net {
    /// A blocking TCP connection to 127.0.0.1, or nil if refused or not accepted in time.
    static func connect(_ port: UInt16, timeout: Double = 3) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 {
            guard errno == EINPROGRESS else { close(fd); return nil }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&p, 1, Int32(timeout * 1000)) == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else {
                close(fd)
                return nil
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    @discardableResult
    static func send(_ fd: Int32, _ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    enum End { case eof, reset, timeout }

    /// Everything until the peer closes, resets or `timeout` passes.
    static func read(_ fd: Int32, timeout: Double) -> (Data, End) {
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return (out, .timeout) }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(max(1, left * 1000)))
            if r == 0 { return (out, .timeout) }
            if r < 0 { if errno == EINTR { continue }; return (out, .reset) }
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { out.append(buf, count: n) } else if n == 0 { return (out, .eof) } else if errno == EINTR || errno == EAGAIN { continue } else { return (out, .reset) }
        }
    }

    /// The first of `count` ports in a row nothing is bound to, below the ephemeral
    /// range so the driver's own client sockets never collide with them.
    static func freePorts(_ count: UInt16 = 1, avoiding: ClosedRange<UInt16>? = nil) -> UInt16 {
        for _ in 0..<500 {
            let base = UInt16.random(in: 20_000...40_000)
            let range = base...base + count - 1
            if let avoiding, range.overlaps(avoiding) { continue }
            if range.allSatisfy(canBind) { return base }
        }
        fatal("no free port")
    }

    private static func canBind(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

struct Response {
    let status: Int
    let headers: [String: String]
    let body: Data
    let elapsed: Double

    var isEmpty200: Bool { status == 200 && body.isEmpty && headers["content-length"] == "0" }
    var isJSON: Bool { status == 200 && headers["content-type"] == "application/json" && headers["content-length"] == "\(body.count)" }
}

enum HTTP {
    static func request(_ port: UInt16, _ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data(),
                        timeout: Double = 5) -> Response? {
        let start = Date()
        guard let fd = Net.connect(port, timeout: min(timeout, 5)) else { return nil }
        defer { close(fd) }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        guard Net.send(fd, Data(head.utf8) + body) else { return nil }
        let (data, _) = Net.read(fd, timeout: timeout)
        return parse(data, elapsed: Date().timeIntervalSince(start))
    }

    static func parse(_ data: Data, elapsed: Double) -> Response? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[end.upperBound...])
        if let n = headers["content-length"].flatMap(Int.init), n >= 0, n <= body.count { body = Data(body.prefix(n)) }
        return Response(status: status, headers: headers, body: body, elapsed: elapsed)
    }
}

/// Work on its own thread, waited for with a timeout.
final class Pending<T> {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: T?
    private var finished: Date?
    let started = Date()

    init(_ work: @escaping () -> T) {
        Thread.detachNewThread { [self] in
            let r = work()
            lock.lock()
            result = r
            finished = Date()
            lock.unlock()
            done.signal()
        }
    }

    /// The result, or nil if it isn't ready within `timeout`.
    func wait(_ timeout: Double) -> T? {
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        done.signal()
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished != nil
    }

    /// Seconds from `since` to when the work finished.
    func finishedAfter(_ since: Date) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return finished.map { $0.timeIntervalSince(since) }
    }
}

/// A shell command fed on stdin, the way Codex runs its hooks.
final class Shell {
    let started = Date()
    private let process = Process()
    private var output: Pending<Data>?

    init(_ command: String, stdin: Data, env: [String: String]) {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = env
        let input = Pipe(), out = Pipe()
        process.standardInput = input
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        guard (try? process.run()) != nil else { return }
        let reader = out.fileHandleForReading
        output = Pending { reader.readDataToEndOfFile() }
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
    }

    /// Exit status, stdout and seconds taken, or nil if it's still running after `timeout`.
    func wait(_ timeout: Double) -> (status: Int32, stdout: Data, elapsed: Double)? {
        guard let output, let data = output.wait(timeout) else { return nil }
        process.waitUntilExit()
        return (process.terminationStatus, data, output.finishedAfter(started) ?? 0)
    }

    func stop() { if process.isRunning { process.terminate() } }
}

// MARK: - Fixture home

/// A temporary folder standing in for the user's home. Nothing outside it is written.
final class Fixture {
    private static var all: [Fixture] = []
    let root: String
    let home: String
    let log: String
    let appLog: String

    init() {
        let base = (tempRoot as NSString).appendingPathComponent("muster-e2e-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        home = root + "/home"
        log = root + "/opened.jsonl"
        appLog = root + "/app.log"
        guard root.hasPrefix(tempRoot + "/") else { fatal("fixture outside the temp folder") }
        mkdir("")
        Self.all.append(self)
    }

    static func cleanupAll() { all.forEach { $0.cleanup() } }

    func path(_ rel: String) -> String { rel.isEmpty ? home : home + "/" + rel }

    func mkdir(_ rel: String) {
        try? FileManager.default.createDirectory(atPath: path(rel), withIntermediateDirectories: true)
    }

    func write(_ rel: String, _ data: Data) {
        mkdir((rel as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: path(rel), contents: data)
    }

    func append(_ rel: String, _ data: Data) {
        guard let fh = FileHandle(forWritingAtPath: path(rel)) else { return write(rel, data) }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }

    func read(_ rel: String) -> Data? { FileManager.default.contents(atPath: path(rel)) }

    func size(_ rel: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: path(rel))[.size] as? Int) ?? 0 }

    func truncate(_ rel: String, to length: Int) { _ = Darwin.truncate(path(rel), off_t(length)) }

    func remove(_ rel: String) { try? FileManager.default.removeItem(atPath: path(rel)) }

    func move(_ rel: String, to other: String) { try? FileManager.default.moveItem(atPath: path(rel), toPath: path(other)) }

    func touch(_ rel: String, _ date: Date) {
        var times = [timeval](repeating: timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0), count: 2)
        _ = utimes(path(rel), &times)
    }

    func chmod(_ rel: String, _ mode: mode_t) { _ = Darwin.chmod(path(rel), mode) }

    /// What the app logged instead of opening, oldest first.
    func opened() -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: log) else { return [] }
        return data.split(separator: 0x0A).compactMap { parseJSON(Data($0)) as? [String: Any] }
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: root) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["-R", "u+rwX", root]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: root)
    }
}

enum SQL {
    /// Runs statements with `?` parameters bound from strings, integers or nil.
    @discardableResult
    static func run(_ path: String, _ sql: String, _ args: [Any?] = []) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, transient)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, n, v)
            default: sqlite3_bind_null(stmt, n)
            }
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }
}

func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

// MARK: - Agent files

/// One Claude Code session: its transcript and, optionally, Claude.app's record of it.
struct ClaudeFixture {
    let fx: Fixture
    let sid: String
    let cwd: String
    var id: String { "claude:" + sid }
    var folder: String { cwd.replacingOccurrences(of: "/", with: "-") }
    var rel: String { ".claude/projects/\(folder)/\(sid).jsonl" }
    var dir: String { ".claude/projects/\(folder)" }

    init(_ fx: Fixture, project: String, sid: String = UUID().uuidString.lowercased()) {
        self.fx = fx
        self.sid = sid
        cwd = fx.root + "/work/" + project
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    }

    private func record(_ type: String, _ message: [String: Any], at: Date, extra: [String: Any] = [:]) -> Data {
        var d: [String: Any] = ["type": type, "timestamp": iso(at), "cwd": cwd, "sessionId": sid, "uuid": UUID().uuidString.lowercased(),
                                "parentUuid": UUID().uuidString.lowercased(), "isSidechain": false, "userType": "external",
                                "version": "2.4.1", "gitBranch": "main", "message": message]
        for (k, v) in extra { d[k] = v }
        return jsonLine(d)
    }

    static func usage(_ scale: Int = 1) -> [String: Any] {
        ["input_tokens": 4 * scale, "cache_creation_input_tokens": 1200 * scale, "cache_read_input_tokens": 24_000 * scale,
         "output_tokens": 180 * scale, "cache_creation": ["ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 1200 * scale],
         "service_tier": "standard"]
    }

    func user(_ text: String, at: Date = Date()) -> Data {
        record("user", ["role": "user", "content": text], at: at)
    }

    func toolUse(_ tool: String, input: [String: Any] = [:], at: Date = Date(), id: String = "msg_" + hex(24)) -> Data {
        record("assistant", ["id": id, "type": "message", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": "tool_use",
                             "content": [["type": "tool_use", "id": "toolu_" + hex(24), "name": tool, "input": input]],
                             "usage": Self.usage()], at: at)
    }

    func ask(_ question: String = "Which database should the cache use?", at: Date = Date()) -> Data {
        toolUse("AskUserQuestion", input: Self.questions(question), at: at)
    }

    static func questions(_ question: String, multiSelect: Bool = false, count: Int = 1) -> [String: Any] {
        ["questions": (0..<count).map { i in
            ["question": i == 0 ? question : question + " (\(i + 1))", "header": "Cache", "multiSelect": multiSelect,
             "options": [["label": "Postgres", "description": "Reuse the main database."],
                         ["label": "SQLite", "description": "A file next to the app."],
                         ["label": "Redis", "description": "A separate service."]]]
        }]
    }

    /// A text block before a tool call; Claude writes one line per block, sharing the message id.
    func text(_ text: String, id: String, at: Date = Date()) -> Data {
        record("assistant", ["id": id, "type": "message", "role": "assistant", "model": "claude-opus-5-5", "stop_reason": NSNull(),
                             "content": [["type": "text", "text": text]], "usage": Self.usage()], at: at)
    }

    func toolResult(_ content: String = "ok", at: Date = Date()) -> Data {
        record("user", ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_" + hex(24), "content": content]]], at: at)
    }

    func reply(_ text: String = "Done.", at: Date = Date()) -> Data {
        record("assistant", ["id": "msg_" + hex(24), "type": "message", "role": "assistant", "model": "claude-opus-5-5",
                             "stop_reason": "end_turn", "content": [["type": "text", "text": text]], "usage": Self.usage()], at: at)
    }

    func apiError(_ text: String = "API Error: 529 overloaded", code: String = "server_error", at: Date = Date()) -> Data {
        record("assistant", ["id": "msg_" + hex(24), "role": "assistant", "model": "<synthetic>", "stop_reason": "stop_sequence",
                             "content": [["type": "text", "text": text]]], at: at, extra: ["isApiErrorMessage": true, "error": code])
    }

    func title(_ t: String) -> Data { jsonLine(["type": "custom-title", "customTitle": t, "sessionId": sid]) }

    func write(_ lines: Data...) { fx.write(rel, lines.reduce(Data(), +)) }
    func append(_ lines: Data...) { fx.append(rel, lines.reduce(Data(), +)) }

    /// Claude.app's session record, which carries the local_ id its deep links take.
    func appRecord(appID: String, title: String, mode: String = "bypassPermissions", activity: Date = Date()) {
        fx.write("Library/Application Support/Claude/claude-code-sessions/acct/org/\(appID).json", json([
            "cliSessionId": sid, "sessionId": appID, "title": title, "isArchived": false, "cwd": cwd,
            "lastActivityAt": ms(activity), "permissionMode": mode, "model": "claude-opus-5-5",
            "remoteMcpServersConfig": ["servers": [["name": "fixture", "url": "https://example.invalid"]]]]))
    }

    /// Exactly what Claude Code posts to a PermissionRequest hook.
    func permissionPayload(command: String, suggestions: [[String: Any]]) -> [String: Any] {
        ["session_id": sid, "transcript_path": fx.path(rel), "cwd": cwd, "permission_mode": "default",
         "hook_event_name": "PermissionRequest", "tool_name": "Bash",
         "tool_input": ["command": command, "description": "Run the migrations"], "permission_suggestions": suggestions]
    }

    /// And to a PreToolUse hook for a tool it matched.
    func preToolUsePayload(tool: String, input: [String: Any]) -> [String: Any] {
        ["session_id": sid, "transcript_path": fx.path(rel), "cwd": cwd, "permission_mode": "default",
         "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input, "tool_use_id": "toolu_" + hex(24)]
    }
}

/// One Codex thread: its row in the state database and its rollout file.
struct CodexFixture {
    let fx: Fixture
    let id: String
    let cwd: String
    var sid: String { id }
    var rel: String { ".codex/sessions/2026/10/12/rollout-2026-10-12T09-00-00-\(id).jsonl" }
    var key: String { "codex:" + id }

    static func dbPath(_ fx: Fixture) -> String { fx.path(".codex/state_5.sqlite") }

    static func createDB(_ fx: Fixture) {
        fx.mkdir(".codex")
        SQL.run(dbPath(fx), "CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, rollout_path TEXT, name TEXT, title TEXT, " +
                "first_user_message TEXT, cwd TEXT, archived INT, updated_at_ms INT)")
    }

    init(_ fx: Fixture, project: String, id: String = UUID().uuidString.lowercased()) {
        self.fx = fx
        self.id = id
        cwd = fx.root + "/work/" + project
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    }

    func register(title: String, at: Date = Date()) {
        SQL.run(Self.dbPath(fx), "INSERT OR REPLACE INTO threads VALUES (?, ?, '', ?, ?, ?, 0, ?)",
                [id, fx.path(rel), title, title, cwd, ms(at)])
    }

    func touchRow(at: Date = Date()) {
        SQL.run(Self.dbPath(fx), "UPDATE threads SET updated_at_ms = ? WHERE id = ?", [ms(at), id])
    }

    private func event(_ type: String, _ payload: [String: Any], at: Date) -> Data {
        jsonLine(["timestamp": iso(at), "type": type, "payload": payload])
    }

    func turnContext(at: Date = Date()) -> Data {
        event("turn_context", ["cwd": cwd, "approval_policy": "on-request", "model": "gpt-6-astra", "effort": "medium"], at: at)
    }

    func started(at: Date = Date()) -> Data { event("event_msg", ["type": "task_started", "model_context_window": 400_000], at: at) }

    func completed(at: Date = Date()) -> Data { event("event_msg", ["type": "task_complete", "last_agent_message": "Done."], at: at) }

    func tokens(_ total: Int, at: Date = Date()) -> Data {
        event("event_msg", ["type": "token_count", "info": ["total_token_usage": [
            "input_tokens": total, "cached_input_tokens": total * 8 / 10, "output_tokens": total / 20, "total_tokens": total + total / 20]]], at: at)
    }

    func call(_ command: String, at: Date = Date()) -> Data {
        event("response_item", ["type": "function_call", "name": "shell", "call_id": "call_" + hex(16),
                                "arguments": String(decoding: json(["command": ["bash", "-lc", command]]), as: UTF8.self)], at: at)
    }

    func output(_ text: String, at: Date = Date()) -> Data {
        event("response_item", ["type": "function_call_output", "call_id": "call_" + hex(16), "output": text], at: at)
    }

    func write(_ lines: Data...) { fx.write(rel, lines.reduce(Data(), +)) }
    func append(_ lines: Data...) { fx.append(rel, lines.reduce(Data(), +)) }

    /// What Codex pipes to a PermissionRequest command hook.
    func permissionPayload(command: String) -> [String: Any] {
        ["session_id": id, "turn_id": UUID().uuidString.lowercased(), "transcript_path": fx.path(rel), "cwd": cwd,
         "hook_event_name": "PermissionRequest", "model": "gpt-6-astra", "permission_mode": "default", "tool_name": "Bash",
         "tool_input": ["command": command, "description": "Run the test suite"]]
    }
}

/// One Cursor agent chat: its transcript and its row in the Agents window's list.
struct CursorFixture {
    let fx: Fixture
    let sid: String
    let cwd: String
    var id: String { "cursor:" + sid }
    var folder: String { "e2e-" + (cwd as NSString).lastPathComponent }
    var rel: String { ".cursor/projects/\(folder)/agent-transcripts/\(sid)/\(sid).jsonl" }

    static let dbRel = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    static func createDB(_ fx: Fixture) {
        fx.mkdir((dbRel as NSString).deletingLastPathComponent)
        SQL.run(fx.path(dbRel), "CREATE TABLE IF NOT EXISTS composerHeaders (composerId TEXT PRIMARY KEY, value TEXT, isSubagent INT, " +
                "isArchived INT, lastUpdatedAt INT, checkpointAt INT)")
    }

    init(_ fx: Fixture, project: String, sid: String = UUID().uuidString.lowercased()) {
        self.fx = fx
        self.sid = sid
        cwd = fx.root + "/work/" + project
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    }

    func query(_ text: String) -> Data {
        jsonLine(["role": "user", "message": ["content": [["type": "text", "text": "<user_query>\n\(text)\n</user_query>"]]]])
    }

    func assistant(_ text: String) -> Data {
        jsonLine(["role": "assistant", "message": ["content": [["type": "text", "text": text]]]])
    }

    func turnEnded(_ status: String = "success") -> Data { jsonLine(["type": "turn_ended", "status": status]) }

    func header(name: String, blocking: Bool, at: Date = Date()) {
        let value = json(["composerId": sid, "name": name, "hasBlockingPendingActions": blocking, "lastUpdatedAt": ms(at),
                          "conversationCheckpointLastUpdatedAt": ms(at), "unifiedMode": "agent",
                          "workspaceIdentifier": ["id": hex(32), "uri": ["fsPath": cwd, "scheme": "file"]]])
        SQL.run(fx.path(Self.dbRel), "INSERT OR REPLACE INTO composerHeaders VALUES (?, ?, 0, 0, ?, NULL)",
                [sid, String(decoding: value, as: UTF8.self), ms(at)])
    }

    func write(_ lines: Data...) { fx.write(rel, lines.reduce(Data(), +)) }
    func append(_ lines: Data...) { fx.append(rel, lines.reduce(Data(), +)) }
}

// MARK: - The app under test

struct State {
    let raw: [String: Any]

    var sessions: [[String: Any]] { raw["sessions"] as? [[String: Any]] ?? [] }
    var ids: [String] { sessions.compactMap { $0["id"] as? String } }
    func session(_ id: String) -> [String: Any]? { sessions.first { $0["id"] as? String == id } }
    func status(_ id: String) -> String? { session(id)?["status"] as? String }
    func unread(_ id: String) -> Bool? { session(id)?["unread"] as? Bool }
    func fault(_ id: String) -> String? { session(id)?["fault"] as? String }
    func promptID(_ id: String) -> String? { session(id)?["promptID"] as? String }
    var prompts: [[String: Any]] { raw["prompts"] as? [[String: Any]] ?? [] }
    func prompt(agent: String, sid: String) -> [String: Any]? { prompts.last { $0["agent"] as? String == agent && $0["sid"] as? String == sid } }
    func panel(_ name: String) -> [String: Any] { (raw["panels"] as? [String: Any])?[name] as? [String: Any] ?? [:] }
    func visible(_ name: String) -> Bool { panel(name)["visible"] as? Bool == true }
    func items(_ name: String) -> [String] { panel(name)["items"] as? [String] ?? [] }
    func selected(_ name: String) -> Int? { panel(name)["selected"] as? Int }
    var alertSession: String? { panel("alert")["session"] as? String }
    /// The alert's key line as text, e.g. "⌥↩ Allow, ⌥⌫ Deny, ⌥↓ Details".
    var alertHints: String? { panel("alert")["hints"] as? String }
    /// Keys Muster holds beyond the switcher and search shortcuts.
    var keys: [String] { raw["keys"] as? [String] ?? [] }
    var whatsNew: String? { raw["whatsNew"] as? String }
    func source(_ agent: String) -> String? { (raw["sources"] as? [String: String])?[agent] }
    func hookSetup(_ agent: String) -> String? { (raw["hookSetup"] as? [String: String])?[agent] }
    var hookPort: UInt16 { UInt16(raw["hookPort"] as? Int ?? 0) }
    func hooks(_ agent: String) -> Bool { (raw["hooks"] as? [String: Bool])?[agent] == true }
    var opened: Int { raw["opened"] as? Int ?? 0 }

    /// What the switcher lists: everything live, then the five latest that finished.
    var switcherPick: [String] {
        let live = sessions.filter { !["done", "idle"].contains($0["status"] as? String ?? "") }
        let recent = sessions.filter { ["done", "idle"].contains($0["status"] as? String ?? "") }.prefix(5)
        return (live + recent).compactMap { $0["id"] as? String }
    }
}

final class App {
    static let bundleID = "dev.muster.e2e"
    static let realPorts: ClosedRange<UInt16> = 47621...47640
    private static var running: [App] = []

    let bundle: String
    let executable: String
    let fixture: Fixture
    let hookBase: UInt16
    private(set) var controlPort: UInt16 = 0
    var ui = false
    var arguments: [String] = []
    private(set) var process: Process?
    private var launchFailure: String?

    var pid: pid_t { process?.processIdentifier ?? 0 }
    var alive: Bool { process?.isRunning == true }
    var version: String { (NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "" }

    init(bundle: String, fixture: Fixture) {
        self.bundle = bundle
        self.fixture = fixture
        let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == Self.bundleID else { fatal("the app bundle's id isn't \(Self.bundleID)") }
        guard info["CFBundleURLTypes"] == nil else { fatal("the e2e bundle must not claim muster:// links") }
        executable = bundle + "/Contents/MacOS/" + (info["CFBundleExecutable"] as? String ?? "")
        hookBase = Net.freePorts(20, avoiding: Self.realPorts)
        Self.running.append(self)
    }

    /// Every variable the app reads, with the ones that could reach real agent data removed.
    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("MUSTER_") { env[k] = nil }
        env["CLAUDE_CONFIG_DIR"] = nil
        env["CODEX_HOME"] = nil
        env["MUSTER_HOME"] = fixture.home
        env["MUSTER_E2E"] = "1"
        env["MUSTER_PORT"] = String(hookBase)
        env["MUSTER_E2E_PORT"] = String(controlPort)
        env["MUSTER_E2E_LOG"] = fixture.log
        if ui { env["MUSTER_E2E_UI"] = "1" }
        return env
    }

    /// Refuses to start anything that could touch real data.
    private func vet(_ env: [String: String]) {
        let real = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        guard let h = env["MUSTER_HOME"], h.hasPrefix(tempRoot + "/"), h != real, !real.hasPrefix(h) else { fatal("MUSTER_HOME isn't a temp fixture") }
        guard env["MUSTER_E2E"] == "1" else { fatal("MUSTER_E2E isn't set") }
        guard env["CLAUDE_CONFIG_DIR"] == nil, env["CODEX_HOME"] == nil else { fatal("CLAUDE_CONFIG_DIR or CODEX_HOME would leak through") }
        guard let p = env["MUSTER_PORT"].flatMap(UInt16.init), !(p...p + 19).overlaps(Self.realPorts) else { fatal("the hook ports overlap the real app's") }
        guard let c = env["MUSTER_E2E_PORT"].flatMap(UInt16.init), !Self.realPorts.contains(c) else { fatal("bad control port") }
    }

    /// Starts the app and waits until its control channel and hook server answer
    /// (demo mode runs no hook server).
    @discardableResult
    func launch(timeout: Double = 15, hooks: Bool = true) -> Bool {
        launchFailure = nil
        for _ in 0..<3 {
            controlPort = Net.freePorts(avoiding: hookBase...hookBase + 19)
            let env = environment()
            vet(env)
            let p = Process()
            // A GUI app launched by launchd gets 256 file descriptors; so does this one.
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "ulimit -n 256 && exec \"$0\" \"$@\"", executable, "-launched", "YES"] + arguments
            p.environment = env
            if !FileManager.default.fileExists(atPath: fixture.appLog) { FileManager.default.createFile(atPath: fixture.appLog, contents: nil) }
            let log = FileHandle(forWritingAtPath: fixture.appLog)
            _ = try? log?.seekToEnd()
            p.standardOutput = log
            p.standardError = log
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { fatal("couldn't start the app: \(error.localizedDescription)") }
            process = p
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, p.isRunning {
                if let s = state(), s.hookPort > 0, let fd = hooks ? Net.connect(s.hookPort, timeout: 0.5) : 0 {
                    if hooks { close(fd) }
                    let real = URL(fileURLWithPath: fixture.home).resolvingSymlinksInPath().path
                    guard s.raw["bundle"] as? String == Self.bundleID, s.raw["e2e"] as? Bool == true,
                          (s.raw["home"] as? String).map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == real,
                          !Self.realPorts.contains(s.hookPort), (s.raw["pid"] as? Int).map(pid_t.init) == p.processIdentifier
                    else { kill9(); fatal("the app isn't in e2e mode against the fixture; stopped it") }
                    return true
                }
                pause(0.05)
            }
            if p.isRunning {
                launchFailure = "startup readiness timed out after \(Int(timeout)) seconds"
                captureStartupSample()
                kill9()
            }
            p.waitUntilExit()
            if p.terminationStatus != 75 { return false }   // 75: the control port was taken; try another
        }
        return false
    }

    /// Preserve a stuck process's stack before stopping it. Only fixture logs are copied.
    private func captureStartupSample() {
        guard let directory = ProcessInfo.processInfo.environment["MUSTER_E2E_DIAGNOSTICS"], !directory.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let prefix = directory + "/startup-\(pid)"
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(pid), "1", "-file", prefix + ".sample.txt"]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        if (try? sample.run()) != nil { sample.waitUntilExit() }
        try? FileManager.default.copyItem(atPath: fixture.appLog, toPath: prefix + ".log")
    }

    func state() -> State? {
        guard controlPort > 0, let r = HTTP.request(controlPort, "GET", "/state", timeout: 3), r.status == 200,
              let d = parseJSON(r.body) as? [String: Any] else { return nil }
        return State(raw: d)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]) -> [String: Any]? {
        guard let r = HTTP.request(controlPort, "POST", path, headers: ["Content-Type": "application/json"], body: json(body), timeout: 5)
        else { return nil }
        return parseJSON(r.body) as? [String: Any]
    }

    /// One control-channel action; see E2E.act in the app.
    @discardableResult
    func act(_ action: String, _ extra: [String: Any] = [:]) -> Bool {
        var body = extra
        body["action"] = action
        return post("/ui", body)?["ok"] as? Bool == true
    }

    func kill9() {
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
    }

    /// Quits through the control channel, then by signal if it has to.
    func stop() {
        guard let p = process, p.isRunning else { return }
        post("/quit", [:])
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { pause(0.05) }
        if p.isRunning { p.terminate() }
        let hard = Date().addingTimeInterval(2)
        while p.isRunning, Date() < hard { pause(0.05) }
        kill9()
    }

    var exitDescription: String {
        if let launchFailure { return launchFailure }
        guard let p = process, !p.isRunning else { return "running" }
        let s = p.terminationStatus
        if p.terminationReason == .uncaughtSignal { return "killed by signal \(s)" }
        return s > 128 ? "crashed with signal \(s - 128)" : "exited with status \(s)"
    }

    /// The first lines of the backtrace the app printed when it crashed, symbols only.
    var crashFrames: [String] {
        let text = (try? String(contentsOfFile: fixture.appLog, encoding: .utf8)) ?? ""
        guard let r = text.range(of: "Muster e2e: crashed", options: .backwards) else { return [] }
        return text[r.upperBound...].split(separator: "\n").prefix(8).compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count > 3 ? parts[3...].joined(separator: " ") : nil
        }
    }

    /// CPU seconds used and physical footprint, from the kernel.
    func usage() -> (cpu: Double, footprint: UInt64, peak: UInt64)? {
        guard alive else { return nil }
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        return (Double(info.ri_user_time + info.ri_system_time) * CPUClock.secondsPerUnit, info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }

    static func stopAll() { running.forEach { $0.stop() } }
}

/// proc_pid_rusage reports CPU time in Mach ticks on Apple silicon and nanoseconds
/// on Intel; calibrated once against getrusage for this process.
enum CPUClock {
    static let secondsPerUnit: Double = {
        var x = 0.0
        let end = Date().addingTimeInterval(0.15)
        while Date() < end { x += sin(x) + 1 }
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let seconds = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        let units = Double(info.ri_user_time + info.ri_system_time)
        guard r == 0, units > 0, seconds > 0, x != 0 else { return 1e-9 }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = Double(tb.numer) / Double(tb.denom) / 1e9
        // Pick whichever unit puts the two clocks closest.
        return abs(units * ticks - seconds) < abs(units * 1e-9 - seconds) ? ticks : 1e-9
    }()
}

func wipeDefaults() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["delete", App.bundleID]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Waiting on state

/// Polls state until `cond` holds, then reports how long it took.
@discardableResult
func expect(_ app: App, _ what: String, within: Double = 2, _ cond: (State) -> Bool) -> Bool {
    let start = Date()
    while true {
        if let s = app.state(), cond(s) {
            check(true, what, secs(Date().timeIntervalSince(start)))
            return true
        }
        if Date().timeIntervalSince(start) > within {
            check(false, what, app.alive ? "not within \(Int(within)) s" : "the app \(app.exitDescription)")
            // MUSTER_E2E_DEBUG=1: what the app reported when the check gave up, to see why.
            if ProcessInfo.processInfo.environment["MUSTER_E2E_DEBUG"] == "1", let s = app.state(),
               let data = try? JSONSerialization.data(withJSONObject: s.raw, options: [.sortedKeys]) {
                note("    state: " + String(decoding: data.prefix(4000), as: UTF8.self))
            }
            return false
        }
        pause(0.04)
    }
}

/// Polls without reporting; the state once `cond` holds, or nil.
func until(_ app: App, within: Double = 2, _ cond: (State) -> Bool) -> State? {
    let start = Date()
    while Date().timeIntervalSince(start) <= within {
        if let s = app.state(), cond(s) { return s }
        pause(0.04)
    }
    return nil
}
