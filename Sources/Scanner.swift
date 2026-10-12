import Foundation
import SQLite3

// Reads live agent sessions straight from the files each app already writes, the
// same files their own windows render from. No hooks, no network.

let home = FileManager.default.homeDirectoryForCurrentUser.path
let recentWindow: TimeInterval = 3 * 3600   // files untouched for longer are not read

// MARK: - JSONL

enum JSONL {
    /// Parsed records from the end of a JSONL file, newest first. Grows the read
    /// window until a record matches `want`, because one tool result can be megabytes.
    /// `parseIf` sees each raw line (and whether `want` is already met) before any
    /// JSON decoding, so readers skip multi-MB lines they don't need.
    static func tail(_ path: String, limit: Int = 400, maxBytes: UInt64 = 8 << 20,
                     parseIf: (Data, Bool) -> Bool = { _, _ in true },
                     want: ([String: Any]) -> Bool = { _ in true }) -> [[String: Any]] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return [] }
        var window: UInt64 = 256 << 10
        while true {
            let start = size > window ? size - window : 0
            let out: [[String: Any]] = autoreleasepool {
                try? fh.seek(toOffset: start)
                let data = fh.readData(ofLength: Int(size - start))
                var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
                if start > 0, !lines.isEmpty { lines.removeFirst() }
                var found: [[String: Any]] = []
                var satisfied = false
                for raw in lines.reversed() {
                    guard parseIf(raw, satisfied),
                          let obj = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
                    found.append(obj)
                    if !satisfied, want(obj) { satisfied = true }
                    if found.count >= limit { break }
                }
                return found
            }
            if start == 0 || out.contains(where: want) || window >= maxBytes { return out }
            window *= 4
        }
    }

    static func has(_ line: Data, _ needles: [[UInt8]]) -> Bool {
        line.withUnsafeBytes { hay in
            guard let base = hay.baseAddress else { return false }
            return needles.contains { n in n.withUnsafeBytes { memmem(base, hay.count, $0.baseAddress, n.count) != nil } }
        }
    }

    static func firstLine(_ path: String) -> [String: Any]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var data = Data()
        while data.count < 4 << 20 {
            let chunk = fh.readData(ofLength: 64 << 10)
            if chunk.isEmpty { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                data.append(chunk[chunk.startIndex..<nl])
                break
            }
            data.append(chunk)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseISO(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

/// Re-parse a file only when its size or modification time changed.
final class FileCache<Value> {
    private var entries: [String: (UInt64, Date, Value)] = [:]

    func value(_ path: String, size: UInt64, mtime: Date, parse: (String) -> Value) -> Value {
        if let e = entries[path], e.0 == size, e.1 == mtime { return e.2 }
        let v = parse(path)
        entries[path] = (size, mtime, v)
        return v
    }
}

struct FileInfo {
    let path: String
    let size: UInt64
    let mtime: Date
}

/// POSIX stat: Foundation's attributesOfItem builds a dictionary per call, which
/// dominated rescans across hundreds of transcripts.
func stat(_ path: String) -> FileInfo? {
    var st = Darwin.stat()
    guard fstatat(AT_FDCWD, path, &st, 0) == 0 else { return nil }
    let t = st.st_mtimespec
    return FileInfo(path: path, size: UInt64(st.st_size), mtime: Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9))
}

func list(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { (dir as NSString).appendingPathComponent($0) }
}

// MARK: - Token usage

/// Running token totals for append-only transcripts, per model. Each call reads
/// only the lines added since the last one (transcripts reach hundreds of MB) and
/// decodes nothing: numbers are read straight from the bytes, messages are keyed
/// by a 64-bit hash of their id and models by a small index, so a scan leaves no
/// per-line allocations behind.
final class UsageTally {
    private struct Entry { var model: UInt16; var usage: Usage }

    private var offsets: [String: UInt64] = [:]
    private var perMessage: [String: [UInt64: Entry]] = [:]
    private var models: [String] = []
    private var modelIndex: [UInt64: UInt16] = [:]
    private static let baseCapacity = 1 << 20
    private var buffer = UnsafeMutableRawPointer.allocate(byteCount: baseCapacity, alignment: 16)
    private var capacity = baseCapacity

    deinit { buffer.deallocate() }

    /// Usage by model for a Claude transcript. Reads through one reused buffer:
    /// allocating a fresh chunk per read leaves the allocator caching freed megabytes.
    func claude(_ path: String) -> [String: Usage] {
        var entries = perMessage[path] ?? [:]
        var offset = offsets[path] ?? 0
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            defer { close(fd) }
            lseek(fd, off_t(offset), SEEK_SET)
            var filled = 0
            while true {
                if filled == capacity { grow() }
                let n = read(fd, buffer + filled, capacity - filled)
                if n <= 0 { break }
                filled += n
                var start = 0
                while start < filled, let nl = memchr(buffer + start, 0x0A, filled - start) {
                    let end = buffer.distance(to: nl)
                    let line = UnsafeRawBufferPointer(start: buffer + start, count: end - start)
                    if let hit = claudeLine(line) { entries[hit.0] = hit.1 }
                    start = end + 1
                }
                offset += UInt64(start)
                memmove(buffer, buffer + start, filled - start)
                filled -= start
            }
            if capacity > 4 * Self.baseCapacity { shrink() }
        }
        offsets[path] = offset
        perMessage[path] = entries
        var byModel: [String: Usage] = [:]
        for e in entries.values { byModel[models[Int(e.model)], default: Usage()] += e.usage }
        return byModel
    }

    private func grow() {
        let bigger = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 16)
        bigger.copyMemory(from: buffer, byteCount: capacity)
        buffer.deallocate()
        buffer = bigger
        capacity *= 2
    }

    private func shrink() {
        buffer.deallocate()
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.baseCapacity, alignment: 16)
        capacity = Self.baseCapacity
    }

    /// Claude writes one line per content block, each repeating the message's usage.
    private func claudeLine(_ line: UnsafeRawBufferPointer) -> (UInt64, Entry)? {
        guard Self.find(line, Self.usageKey) != nil,
              Self.find(line, Self.assistantKey) != nil || Self.find(line, Self.assistantKeySpaced) != nil,
              let id = Self.hashValue(line, after: Self.idKeys), let usage = Self.usage(line) else { return nil }
        return (id, Entry(model: model(line), usage: usage))
    }

    /// The message's model, interned: the string is only created the first time.
    private func model(_ line: UnsafeRawBufferPointer) -> UInt16 {
        guard let (hash, range) = Self.quoted(line, after: Self.modelKeys) else { return internModel("unknown", hash: 0) }
        if let i = modelIndex[hash] { return i }
        return internModel(String(decoding: UnsafeRawBufferPointer(rebasing: line[range]), as: UTF8.self), hash: hash)
    }

    private func internModel(_ name: String, hash: UInt64) -> UInt16 {
        if let i = modelIndex[hash] { return i }
        models.append(name)
        let i = UInt16(models.count - 1)
        modelIndex[hash] = i
        return i
    }

    private static let usageKey = Array("\"usage\"".utf8)
    private static let assistantKey = Array("\"type\":\"assistant\"".utf8)
    private static let assistantKeySpaced = Array("\"type\": \"assistant\"".utf8)
    private static let idKeys = [Array("\"id\":\"msg_".utf8), Array("\"id\": \"msg_".utf8)]
    private static let modelKeys = [Array("\"model\":\"".utf8), Array("\"model\": \"".utf8)]

    static func find(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
        let end = to ?? hay.count
        guard let base = hay.baseAddress, end - from >= needle.count else { return nil }
        return needle.withUnsafeBytes { n in
            memmem(base + from, end - from, n.baseAddress, needle.count).map { base.distance(to: $0) }
        }
    }

    /// FNV-1a of the quoted value following the first matching key, and its range.
    private static func quoted(_ line: UnsafeRawBufferPointer, after keys: [[UInt8]]) -> (UInt64, Range<Int>)? {
        for key in keys {
            guard let at = find(line, key) else { continue }
            var h: UInt64 = 0xcbf29ce484222325
            let start = at + key.count
            var i = start
            while i < line.count, line[i] != 0x22 {
                h = (h ^ UInt64(line[i])) &* 0x100000001b3
                i += 1
            }
            return (h, start..<i)
        }
        return nil
    }

    private static func hashValue(_ line: UnsafeRawBufferPointer, after keys: [[UInt8]]) -> UInt64? {
        quoted(line, after: keys)?.0
    }

    /// Top-level integers of the last structural `"usage": {...}`. It follows the
    /// message content, where escaped copies (\"usage\") can appear in tool output;
    /// nested objects are skipped by depth, except the 5-minute / 1-hour split of
    /// cache writes, which prices differently.
    private static func usage(_ line: UnsafeRawBufferPointer) -> Usage? {
        var last: Int?
        var from = 0
        while let at = find(line, usageKey, from: from) {
            if at > 0, line[at - 1] != 0x5C { last = at }
            from = at + 1
        }
        guard let at = last else { return nil }
        var i = at + usageKey.count
        while i < line.count, line[i] == 0x20 || line[i] == 0x3A { i += 1 }
        guard i < line.count, line[i] == 0x7B else { return nil }
        let objectStart = i
        var input = 0, read = 0, write = 0, output = 0
        var depth = 0
        while i < line.count {
            let c = line[i]
            if c == 0x22 {
                let keyStart = i + 1
                i = keyStart
                while i < line.count, line[i] != 0x22 { i += line[i] == 0x5C ? 2 : 1 }
                let keyEnd = i
                i += 1
                guard depth == 1, let (value, next) = integer(line, after: i) else { continue }
                switch keyName(line, keyStart, keyEnd) {
                case "input_tokens": input = value
                case "cache_read_input_tokens": read = value
                case "cache_creation_input_tokens": write = value
                case "output_tokens": output = value
                default: break
                }
                i = next
                continue
            }
            if c == 0x7B || c == 0x5B { depth += 1 } else if c == 0x7D || c == 0x5D {
                depth -= 1
                if depth == 0 {
                    let hour = find(line, oneHourKey, from: objectStart, to: i).flatMap { integer(line, after: $0 + oneHourKey.count)?.0 } ?? 0
                    return Usage(input: input, cacheWrite5m: max(0, write - hour), cacheWrite1h: hour, cacheRead: read, output: output)
                }
            }
            i += 1
        }
        return nil
    }

    private static let oneHourKey = Array("\"ephemeral_1h_input_tokens\"".utf8)

    /// `: 123` after a key, returning the value and the index after it.
    private static func integer(_ line: UnsafeRawBufferPointer, after start: Int) -> (Int, Int)? {
        var j = start
        while j < line.count, line[j] == 0x20 { j += 1 }
        guard j < line.count, line[j] == 0x3A else { return nil }
        j += 1
        while j < line.count, line[j] == 0x20 { j += 1 }
        var value = 0, digits = 0
        while j < line.count, line[j] >= 0x30, line[j] <= 0x39 {
            value = value * 10 + Int(line[j] - 0x30)
            j += 1
            digits += 1
        }
        return digits > 0 ? (value, j) : nil
    }

    private static let wanted = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
        .map { (Array($0.utf8), $0) }

    private static func keyName(_ line: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> String? {
        guard let base = line.baseAddress else { return nil }
        for (bytes, name) in wanted where bytes.count == end - start {
            if bytes.withUnsafeBytes({ memcmp(base + start, $0.baseAddress, bytes.count) }) == 0 { return name }
        }
        return nil
    }
}

// MARK: - SQLite (read-only)

enum SQLiteRO {
    /// Rows of the query as strings / integers. Opens read-only and never writes,
    /// so it is safe against the apps' live databases.
    static func rows(_ path: String, _ sql: String, _ binds: [Int64] = []) -> [[Any?]]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in binds.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), v) }
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c) { row.append(String(data: Data(bytes: p, count: n), encoding: .utf8)) } else { row.append(nil) }
                default: row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }
}

/// Top-level scalar fields of a JSON object, read from the bytes without decoding
/// the rest. Claude.app's session records carry a ~1 MB MCP config blob per file;
/// decoding it to read ten small fields scatters the heap. Nested values only
/// register as present (`true`), which is all callers need for them.
func topLevelScalars(_ data: Data, _ keys: Set<String>) -> [String: Any] {
    var out: [String: Any] = [:]
    data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
        var i = 0, depth = 0
        func skipString(_ k: inout Int) { k += 1; while k < b.count, b[k] != 0x22 { k += b[k] == 0x5C ? 2 : 1 }; k += 1 }
        while i < b.count {
            let c = b[i]
            if c == 0x22 {
                let start = i
                skipString(&i)
                guard depth == 1 else { continue }
                var j = i
                while j < b.count, b[j] == 0x20 || b[j] == 0x0A || b[j] == 0x0D || b[j] == 0x09 { j += 1 }
                guard j < b.count, b[j] == 0x3A else { continue }
                let key = String(decoding: UnsafeRawBufferPointer(rebasing: b[start + 1..<i - 1]), as: UTF8.self)
                j += 1
                while j < b.count, b[j] == 0x20 || b[j] == 0x0A || b[j] == 0x0D || b[j] == 0x09 { j += 1 }
                guard j < b.count, keys.contains(key) else { i = j; continue }
                switch b[j] {
                case 0x22:
                    var e = j
                    skipString(&e)
                    let literal = Data(UnsafeRawBufferPointer(rebasing: b[j..<e]))
                    out[key] = (try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed)) as? String
                    i = e
                case 0x74: out[key] = true; i = j
                case 0x66: out[key] = false; i = j
                case 0x6E: i = j
                case 0x7B, 0x5B: out[key] = true; i = j
                default:
                    var e = j
                    while e < b.count, b[e] != 0x2C, b[e] != 0x7D, b[e] != 0x20, b[e] != 0x0A { e += 1 }
                    out[key] = Double(String(decoding: UnsafeRawBufferPointer(rebasing: b[j..<e]), as: UTF8.self))
                    i = e
                }
                continue
            }
            if c == 0x7B || c == 0x5B { depth += 1 } else if c == 0x7D || c == 0x5D { depth -= 1 }
            i += 1
        }
    }
    return out
}

func jsonObject(_ s: Any?) -> [String: Any]? {
    guard let s = s as? String, let d = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

// MARK: - Claude (Claude.app local + SSH sessions, Claude Code CLI)

final class ClaudeReader {
    static let subagentLive: TimeInterval = 180     // a subagent this fresh keeps its parent working
    static let permissionWait: TimeInterval = 15    // unanswered tool call in a prompting mode
    static let appTurnLive: TimeInterval = 600
    static let promptingModes: Set<String> = ["default", "acceptEdits", "plan"]
    static let noPromptTools: Set<String> = ["Read", "Glob", "Grep", "LS", "TodoWrite", "Task", "Agent", "WebSearch", "Monitor"]
    static let waitingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    struct FileState {
        var status: Status
        var since: Date
        var title: String
        var cwd: String
        var tools: [String]
    }

    struct AppRecord {
        var appID: String
        var title: String
        var archived: Bool
        var activity: Date
        var turnOpen: Bool
        var cwd: String
        var permissionMode: String
        var errorAt: Date?
    }

    private let files = FileCache<FileState?>()
    private let subagents = FileCache<(String, Date)?>()
    private let records = FileCache<(String, AppRecord)?>()
    private let usage = UsageTally()
    private let root: String
    private let appRoot: String
    private(set) var state: SourceState = .notInstalled

    /// CLAUDE_CONFIG_DIR moves ~/.claude, as it does for Claude Code itself.
    init(home: String = home, configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]) {
        root = (configDir ?? home + "/.claude") + "/projects"
        appRoot = home + "/Library/Application Support/Claude/claude-code-sessions"
    }

    var watchPaths: [String] { [root, appRoot] }

    private static func isTurn(_ d: [String: Any]) -> Bool {
        let t = d["type"] as? String
        return ((t == "user" || t == "assistant") && (d["isSidechain"] as? Bool) != true)
            || (t == "system" && d["subtype"] as? String == "stop_hook_summary")
    }

    private static let customTitle = [Array("custom-title".utf8)]

    private static func parse(_ path: String) -> FileState? {
        let recs = JSONL.tail(path, parseIf: { line, haveTurn in !haveTurn || JSONL.has(line, customTitle) }, want: isTurn)
        let title = recs.first { $0["type"] as? String == "custom-title" }?["customTitle"] as? String ?? ""
        let cwd = recs.lazy.compactMap { $0["cwd"] as? String }.first ?? ""
        guard let last = recs.first(where: isTurn) else { return nil }
        let since = parseISO(last["timestamp"]) ?? .distantPast
        let msg = last["message"] as? [String: Any] ?? [:]
        var tools: [String] = []
        let status: Status
        switch last["type"] as? String {
        case "system":
            status = .done
        case "assistant":
            let content = msg["content"] as? [[String: Any]] ?? []
            tools = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["name"] as? String }
            let stop = msg["stop_reason"] as? String
            if stop == "tool_use" || !tools.isEmpty {
                status = waitingTools.isDisjoint(with: tools) ? .working : .needsYou
            } else if last["isApiErrorMessage"] as? Bool == true {
                status = .error
            } else if ["end_turn", "stop_sequence", "max_tokens"].contains(stop ?? "") {
                status = .done
            } else {
                status = .working
            }
        default:
            var text = msg["content"] as? String ?? ""
            if let parts = msg["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            }
            status = text.contains("[Request interrupted by user") ? .done : .working
        }
        return FileState(status: status, since: since, title: title, cwd: cwd, tools: tools)
    }

    private static func parseSubagent(_ path: String) -> (String, Date)? {
        let recs = JSONL.tail(path, limit: 5, want: { $0["sessionId"] != nil })
        guard let d = recs.first(where: { $0["sessionId"] is String }), let sid = d["sessionId"] as? String else { return nil }
        return (sid, parseISO(d["timestamp"]) ?? .distantPast)
    }

    private static let recordKeys: Set<String> = ["cliSessionId", "sessionId", "title", "isArchived", "lastActivityAt",
                                                  "lastAssistantUuid", "postTurnSummaryFor", "cwd", "permissionMode",
                                                  "error", "errorAt"]

    private static func parseRecord(_ path: String) -> (String, AppRecord)? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let d = topLevelScalars(data, recordKeys)
        guard let cli = d["cliSessionId"] as? String else { return nil }
        let last = d["lastAssistantUuid"] as? String
        let ms = { (k: String) in Date(timeIntervalSince1970: ((d[k] as? Double) ?? 0) / 1000) }
        return (cli, AppRecord(
            appID: d["sessionId"] as? String ?? "",
            title: d["title"] as? String ?? "",
            archived: d["isArchived"] as? Bool ?? false,
            activity: ms("lastActivityAt"),
            turnOpen: last != nil && d["postTurnSummaryFor"] as? String != last,
            cwd: d["cwd"] as? String ?? "",
            permissionMode: d["permissionMode"] as? String ?? "",
            errorAt: d["error"] != nil ? ms("errorAt") : nil))
    }

    /// Claude.app's own session list, keyed by transcript id: its deep links take the
    /// app id (local_…), its titles are the sidebar's, and it knows when a turn is open.
    private func appIndex() -> [String: AppRecord] {
        var index: [String: AppRecord] = [:]
        for a in list(appRoot) { for b in list(a) { for path in list(b) where path.hasSuffix(".json") && (path as NSString).lastPathComponent.hasPrefix("local_") {
            guard let f = stat(path), Date().timeIntervalSince(f.mtime) <= 24 * 3600,
                  let r = records.value(path, size: f.size, mtime: f.mtime, parse: Self.parseRecord) else { continue }
            index[r.0] = r.1
        } } }
        return index
    }

    func scan(now: Date) -> [Session] {
        let app = appIndex()
        var out: [String: Session] = [:]
        var pending: [String: [String]] = [:]
        var paths: [String: String] = [:]
        var subLast: [String: Date] = [:]

        for project in list(root) {
            for path in list(project) {
                if path.hasSuffix(".jsonl") {
                    guard let f = stat(path), now.timeIntervalSince(f.mtime) <= recentWindow,
                          let s = files.value(path, size: f.size, mtime: f.mtime, parse: Self.parse) else { continue }
                    let sid = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    let a = app[sid]
                    if a?.archived == true { continue }
                    paths[sid] = path
                    pending[sid] = s.tools
                    out[sid] = Session(agent: .claude, sid: sid, status: s.status, since: s.since,
                                       title: (a?.title).flatMap { $0.isEmpty ? nil : $0 } ?? s.title,
                                       project: s.cwd, appID: a?.appID ?? "")
                } else {
                    for sub in list(path + "/subagents") where sub.hasSuffix(".jsonl") {
                        guard let f = stat(sub), now.timeIntervalSince(f.mtime) <= 3600,
                              let hit = subagents.value(sub, size: f.size, mtime: f.mtime, parse: Self.parseSubagent) else { continue }
                        subLast[hit.0] = max(subLast[hit.0] ?? .distantPast, hit.1)
                    }
                }
            }
        }

        for (sid, var o) in out {
            if let path = paths[sid] {
                var byModel = usage.claude(path)
                for sub in list(String(path.dropLast(6)) + "/subagents") where sub.hasSuffix(".jsonl") {
                    byModel.merge(usage.claude(sub), uniquingKeysWith: +)
                }
                o.account(byModel)
            }
            if let sub = subLast[sid], o.status == .done, sub > o.since {
                o.status = now.timeIntervalSince(sub) <= Self.subagentLive ? .working : .done
                o.since = sub
            }
            out[sid] = o
        }

        for (sid, a) in app where !a.archived {
            if a.turnOpen, now.timeIntervalSince(a.activity) <= Self.appTurnLive {
                if var o = out[sid] {
                    if o.status != .needsYou, a.activity > o.since { o.status = .working; o.since = a.activity }
                    out[sid] = o
                } else {
                    out[sid] = Session(agent: .claude, sid: sid, status: .working, since: a.activity,
                                       title: a.title, project: a.cwd, appID: a.appID)
                }
            }
            guard var o = out[sid] else { continue }
            if let e = a.errorAt, e >= o.since, now.timeIntervalSince(e) <= recentWindow {
                o.status = .error
                o.since = e
            }
            // Permission prompts are never written to disk. In a mode that can prompt,
            // a tool call left unanswered this long is almost always one.
            if o.status == .working, Self.promptingModes.contains(a.permissionMode),
               let tools = pending[sid], !tools.isEmpty, !Set(tools).isSubset(of: Self.noPromptTools),
               now.timeIntervalSince(max(o.since, a.activity)) >= Self.permissionWait {
                o.status = .needsYou
            }
            out[sid] = o
        }
        let installed = FileManager.default.fileExists(atPath: root) || FileManager.default.fileExists(atPath: appRoot)
        state = installed ? .ok(out.count) : .notInstalled
        return Array(out.values)
    }
}

// MARK: - Codex (desktop app and CLI)

final class CodexReader {
    private static let eventKeys = ["token_count", "task_started", "task_complete", "turn_aborted", "turn_context"].map { Array($0.utf8) }
    private let files = FileCache<(Status, Date, [String: Usage])?>()
    private let root: String
    private(set) var state: SourceState = .notInstalled

    /// CODEX_HOME moves ~/.codex, as it does for Codex itself.
    init(home: String = home, codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"]) {
        root = codexHome ?? home + "/.codex"
    }

    var watchPaths: [String] { [root] }

    private static func parse(_ path: String) -> (Status, Date, [String: Usage])? {
        let kinds: Set<String> = ["task_started", "task_complete", "turn_aborted"]
        let recs = JSONL.tail(path, parseIf: { line, _ in JSONL.has(line, eventKeys) },
                              want: { kinds.contains(($0["payload"] as? [String: Any])?["type"] as? String ?? "") })
        // token_count carries running totals for the whole thread; the model comes
        // from the latest turn_context. Input includes the cached part.
        var usage: [String: Usage] = [:]
        let model = recs.lazy.compactMap { d -> String? in
            let p = d["payload"] as? [String: Any]
            return d["type"] as? String == "turn_context" ? p?["model"] as? String : nil
        }.first ?? "unknown"
        for d in recs {
            let p = d["payload"] as? [String: Any] ?? [:]
            if p["type"] as? String == "token_count", let info = p["info"] as? [String: Any] {
                let t = info["total_token_usage"] as? [String: Any] ?? [:]
                let n = { (k: String) in (t[k] as? NSNumber)?.intValue ?? 0 }
                let cached = n("cached_input_tokens"), write = n("cache_write_input_tokens")
                usage[model] = Usage(input: max(0, n("input_tokens") - cached - write), cacheWrite5m: write, cacheWrite1h: 0,
                                     cacheRead: cached, output: n("output_tokens"))
                break
            }
        }
        for d in recs {
            switch (d["payload"] as? [String: Any])?["type"] as? String {
            case "task_started": return (.working, parseISO(d["timestamp"]) ?? .distantPast, usage)
            case "task_complete", "turn_aborted": return (.done, parseISO(d["timestamp"]) ?? .distantPast, usage)
            default: continue
            }
        }
        return nil
    }

    func scan(now: Date) -> [Session] {
        let dbs = list(root).filter { ($0 as NSString).lastPathComponent.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        let newest = dbs.max { version($0) < version($1) }
        guard FileManager.default.fileExists(atPath: root) else { state = .notInstalled; return [] }
        guard let db = newest else { state = .unreadable("Codex is installed but has no thread database yet"); return [] }
        guard let rows = SQLiteRO.rows(db,
            "SELECT id, rollout_path, COALESCE(NULLIF(name,''), NULLIF(title,''), first_user_message, ''), cwd " +
            "FROM threads WHERE archived = 0 AND updated_at_ms > ?", [Int64((now.timeIntervalSince1970 - recentWindow) * 1000)])
        else { state = .unreadable("Can't read Codex's thread list. Its format may have changed."); return [] }
        let found: [Session] = rows.compactMap { r in
            guard let id = r[0] as? String, let path = r[1] as? String, let f = stat(path),
                  let res = files.value(path, size: f.size, mtime: f.mtime, parse: Self.parse) else { return nil }
            var s = Session(agent: .codex, sid: id, status: res.0, since: res.1,
                            title: String((r[2] as? String ?? "").prefix(80)), project: r[3] as? String ?? "", appID: "")
            s.account(res.2)
            return s
        }
        state = .ok(found.count)
        return found
    }

    private func version(_ path: String) -> Int {
        Int(((path as NSString).lastPathComponent as NSString).deletingPathExtension.split(separator: "_").last ?? "") ?? -1
    }
}

// MARK: - Cursor agent chats

final class CursorReader {
    static let activeWindow: TimeInterval = 600   // a checkpoint this recent with no turn end counts as running
    static let endSlack: TimeInterval = 30         // turn_ended can land just before the final checkpoint

    private let files = FileCache<(Status, Date, String)>()
    private var workspaces: [String: String] = [:]
    private let root: String
    private let db: String
    private(set) var state: SourceState = .notInstalled
    private var headersReadable = true

    init(home: String = home) {
        root = home + "/.cursor/projects"
        db = home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    var watchPaths: [String] { [root, (db as NSString).deletingLastPathComponent] }

    private static func parse(_ path: String) -> (Status, Date, String) {
        let last = JSONL.tail(path, limit: 3).first ?? [:]
        let mtime = stat(path)?.mtime ?? .distantPast
        let status: Status = last["type"] as? String == "turn_ended" ? (last["status"] as? String == "error" ? .error : .done) : .working
        var title = ""
        if let first = JSONL.firstLine(path), let msg = first["message"] as? [String: Any],
           let parts = msg["content"] as? [[String: Any]], var text = parts.first?["text"] as? String {
            if let r = text.range(of: "<user_query>") {
                text = String(text[r.upperBound...])
                if let e = text.range(of: "</user_query>") { text = String(text[..<e.lowerBound]) }
            }
            title = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
        }
        return (status, mtime, title)
    }

    /// Cursor names each project folder after its workspace path with separators
    /// turned into '-'; walk the filesystem to recover the real path.
    private func workspace(_ folder: String) -> String {
        if let hit = workspaces[folder] { return hit }
        let parts = folder.split(separator: "-").map(String.init)
        func walk(_ base: String, _ i: Int) -> String? {
            if i == parts.count { return base }
            for j in stride(from: parts.count, to: i, by: -1) {
                for joiner in ["-", " ", ".", "_"] {
                    let cand = (base as NSString).appendingPathComponent(parts[i..<j].joined(separator: joiner))
                    var dir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: cand, isDirectory: &dir), dir.boolValue, let found = walk(cand, j) {
                        return found
                    }
                }
            }
            return nil
        }
        let found = walk("/", 0) ?? ""
        workspaces[folder] = found
        return found
    }

    private var headerCache: (key: [Date], value: [String: [String: Any]])?

    /// The Agents window's chat list, re-read only when the database or its WAL changes.
    private func headers(now: Date) -> [String: [String: Any]] {
        let key = [db, db + "-wal"].map { stat($0)?.mtime ?? .distantPast }
        if let c = headerCache, c.key == key { return c.value }
        var out: [String: [String: Any]] = [:]
        let cutoff = Int64((now.timeIntervalSince1970 - recentWindow) * 1000)
        let rows = SQLiteRO.rows(db, "SELECT composerId, value FROM composerHeaders WHERE isSubagent = 0 AND isArchived = 0 " +
                                 "AND MAX(lastUpdatedAt, COALESCE(checkpointAt, 0)) > ?", [cutoff])
        headersReadable = rows != nil || !FileManager.default.fileExists(atPath: db)
        for r in rows ?? [] {
            if let id = r[0] as? String, let h = jsonObject(r[1]) { out[id] = h }
        }
        headerCache = (key, out)
        return out
    }

    func scan(now: Date) -> [Session] {
        var fromFiles: [String: (Status, Date, String, String)] = [:]
        for project in list(root) {
            for dir in list(project + "/agent-transcripts") {
                let sid = (dir as NSString).lastPathComponent
                let path = dir + "/\(sid).jsonl"
                guard let f = stat(path), now.timeIntervalSince(f.mtime) <= recentWindow else { continue }
                let r = files.value(path, size: f.size, mtime: f.mtime, parse: Self.parse)
                fromFiles[sid] = (r.0, r.1, r.2, (project as NSString).lastPathComponent)
            }
        }
        let headers = self.headers(now: now)

        var out: [Session] = []
        for sid in Set(fromFiles.keys).union(headers.keys) {
            let h = headers[sid] ?? [:]
            var (status, since, title, folder) = fromFiles[sid] ?? (.working, .distantPast, "", "")
            let ws = (((h["workspaceIdentifier"] as? [String: Any])?["uri"] as? [String: Any])?["fsPath"] as? String)
                ?? (folder.isEmpty ? "" : workspace(folder))
            let ms = max((h["conversationCheckpointLastUpdatedAt"] as? NSNumber)?.doubleValue ?? 0,
                         (h["lastUpdatedAt"] as? NSNumber)?.doubleValue ?? 0)
            let activity = Date(timeIntervalSince1970: ms / 1000)
            if h["hasBlockingPendingActions"] as? Bool == true {
                status = .needsYou
                since = max(activity, since)
            } else if fromFiles[sid] != nil, status == .done || status == .error, since >= activity.addingTimeInterval(-Self.endSlack) {
            } else if activity > since, now.timeIntervalSince(activity) <= Self.activeWindow {
                status = .working
                since = activity
            } else if fromFiles[sid] == nil {
                continue
            }
            out.append(Session(agent: .cursor, sid: sid, status: status, since: since,
                               title: (h["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title,
                               project: ws, appID: ""))
        }
        if !FileManager.default.fileExists(atPath: root) && !FileManager.default.fileExists(atPath: db) {
            state = .notInstalled
        } else if !headersReadable {
            state = .unreadable("Can't read Cursor's chat list. Its format may have changed.")
        } else {
            state = .ok(out.count)
        }
        return out
    }
}
