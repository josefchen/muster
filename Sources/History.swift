import Foundation

// Thirty days of token usage for the Usage window, read on this Mac from the
// transcripts Claude and Codex already write. Nothing is sent anywhere. Each
// file's messages are cached by path, size and modification time, so reopening
// reads only what changed, and a growing transcript only from where it stopped.

/// The last 30 local days, oldest first, as the Usage window shows them.
struct UsageHistory {
    struct Day {
        var start: Date
        var tokens: [Agent: Int] = [:]
        var cost: [Agent: Double] = [:]
    }

    struct Row: Identifiable {
        let id: String           // grouping key: model id or project path
        let name: String
        var agent: Agent?        // set when every token came from one agent
        var tokens = 0
        var cost = 0.0           // priced tokens only
        var unpriced = false     // some tokens came from models with no known price
    }

    var days: [Day]
    var models: [Row]            // most tokens first
    var projects: [Row]

    var tokens: Int { days.reduce(0) { $0 + $1.tokens.values.reduce(0, +) } }
    var cost: Double { days.reduce(0) { $0 + $1.cost.values.reduce(0, +) } }
    var unpriced: Bool { models.contains { $0.unpriced } }
}

/// What the last scan read, for measuring it.
struct HistoryStats {
    var files = 0
    var cached = 0               // unchanged since the last scan
    var appended = 0             // grew; read from where the last scan stopped
    var parsed = 0               // new or rewritten; read in full
    var bytes: UInt64 = 0        // size of every file in range
    var bytesRead: UInt64 = 0
}

/// Local midnights for the last `count` days, oldest first.
struct DayWindow {
    let starts: [Int64]
    let end: Int64

    init(now: Date, count: Int = History.days, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        starts = (0..<count).map { i in
            Int64(calendar.date(byAdding: .day, value: i - count + 1, to: today)!.timeIntervalSince1970)
        }
        end = Int64(calendar.date(byAdding: .day, value: 1, to: today)!.timeIntervalSince1970)
    }

    var start: Int64 { starts[0] }

    func day(_ t: Int64) -> Int? {
        guard t >= start, t < end else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

final class History {
    static let days = 30
    static let cacheVersion: UInt64 = 1

    private let claudeRoot: String
    private let codexRoot: String
    private let cachePath: String
    private let reader = LineReader()
    private(set) var stats = HistoryStats()

    /// CLAUDE_CONFIG_DIR and CODEX_HOME move the agents' folders, as for the live readers.
    init(home: String = home, configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
         codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"], cachePath: String? = nil) {
        claudeRoot = (configDir ?? home + "/.claude") + "/projects"
        codexRoot = codexHome ?? home + "/.codex"
        self.cachePath = cachePath ?? home + "/Library/Application Support/Muster/usage-cache.bin"
    }

    /// Reads what changed since the last scan and totals the last 30 days. Returns nil
    /// when cancelled; the files read so far are still cached for next time.
    func scan(now: Date = Date(), progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) -> UsageHistory? {
        stats = HistoryStats()
        let window = DayWindow(now: now)
        let sources = autoreleasepool { self.sources(since: window.start) }
        let old = CacheFile(path: cachePath)
        let plans = sources.map { plan($0, old) }
        stats.files = sources.count
        stats.bytes = sources.reduce(0) { $0 + $1.size }
        let toRead = max(1, plans.reduce(UInt64(0)) { $0 + $1.bytesToRead })

        let out = CacheWriter(path: cachePath)
        var totals = Totals(window: window)
        var stopped = false
        var reported: UInt64 = 0
        withExtendedLifetime(old) {
            for (source, plan) in zip(sources, plans) {
                if !stopped, cancelled() { stopped = true }
                if stopped {
                    if let body = plan.cached { out.append(body) }
                    continue
                }
                autoreleasepool {
                    switch plan.kind {
                    case .unchanged:
                        stats.cached += 1
                        let record = FileRecord(decoding: plan.cached!)
                        if let record { totals.add(record, source); out.append(plan.cached!); return }
                        stats.cached -= 1
                        fallthrough
                    case .new:
                        stats.parsed += 1
                        var record = FileRecord(path: source.path, agent: source.agent)
                        read(source, into: &record)
                        totals.add(record, source)
                        out.append(record.encoded())
                    case .grown:
                        stats.appended += 1
                        var record = FileRecord(decoding: plan.cached!) ?? FileRecord(path: source.path, agent: source.agent)
                        read(source, into: &record)
                        totals.add(record, source)
                        out.append(record.encoded())
                    }
                }
                if stats.bytesRead - reported >= 16 << 20 {
                    reported = stats.bytesRead
                    progress(min(1, Double(stats.bytesRead) / Double(toRead)))
                }
            }
        }
        out.finish()
        return stopped ? nil : totals.history()
    }

    // MARK: Sources

    struct Source {
        let path: String
        let size: UInt64
        let mtime: Date
        let agent: Agent
        let project: String      // Claude: the project folder, for lines with no cwd. Codex: the thread's cwd.
        let model: String        // Codex: the thread's model, for rollouts that never name one
    }

    /// Every transcript touched since `since`, sorted by path so duplicates resolve
    /// the same way on every scan.
    private func sources(since: Int64) -> [Source] {
        var out: [Source] = []
        let cutoff = Date(timeIntervalSince1970: TimeInterval(since))
        for project in list(claudeRoot) {
            let folder = (project as NSString).lastPathComponent
            walk(project) { path in
                guard let f = stat(path), f.mtime >= cutoff else { return }
                out.append(Source(path: path, size: f.size, mtime: f.mtime, agent: .claude, project: folder, model: ""))
            }
        }
        var seen = Set<String>()
        for (path, cwd, model) in codexThreads(since: since) where seen.insert(path).inserted {
            guard let f = stat(path), f.mtime >= cutoff else { continue }
            out.append(Source(path: path, size: f.size, mtime: f.mtime, agent: .codex, project: cwd, model: model))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Transcripts at any depth: subagents sit in <session>/subagents and its workflows folders.
    private func walk(_ dir: String, _ visit: (String) -> Void) {
        for path in list(dir) {
            if path.hasSuffix(".jsonl") { visit(path); continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { walk(path, visit) }
        }
    }

    private func codexThreads(since: Int64) -> [(String, String, String)] {
        let dbs = list(codexRoot).filter { ($0 as NSString).lastPathComponent.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
        func version(_ p: String) -> Int {
            Int(((p as NSString).lastPathComponent as NSString).deletingPathExtension.split(separator: "_").last ?? "") ?? -1
        }
        guard let db = dbs.max(by: { version($0) < version($1) }) else { return [] }
        let ms = [since * 1000]
        let rows = SQLiteRO.rows(db, "SELECT rollout_path, cwd, COALESCE(model, '') FROM threads WHERE updated_at_ms > ?", ms)
            ?? SQLiteRO.rows(db, "SELECT rollout_path, cwd, '' FROM threads WHERE updated_at_ms > ?", ms) ?? []
        return rows.compactMap { r in
            guard let path = r[0] as? String else { return nil }
            return (path, r[1] as? String ?? "", r[2] as? String ?? "")
        }
    }

    // MARK: Cache plans

    private struct Plan {
        enum Kind { case unchanged, grown, new }
        let kind: Kind
        let cached: UnsafeRawBufferPointer?
        let bytesToRead: UInt64
    }

    /// Decided from each record's header alone, so only one file's events are in memory at a time.
    private func plan(_ s: Source, _ cache: CacheFile) -> Plan {
        guard let body = cache.records[s.path], let record = FileRecord(decoding: body, headerOnly: true), record.agent == s.agent else {
            return Plan(kind: .new, cached: nil, bytesToRead: s.size)
        }
        if record.size == s.size, record.mtime == s.mtime.timeIntervalSince1970 {
            return Plan(kind: .unchanged, cached: body, bytesToRead: 0)
        }
        if record.offset > 0, record.offset <= s.size, tailHash(s.path, before: record.offset) == record.tail {
            return Plan(kind: .grown, cached: body, bytesToRead: s.size - record.offset)
        }
        return Plan(kind: .new, cached: body, bytesToRead: s.size)
    }

    /// FNV-1a of up to 64 bytes before `offset`: if they still match, the file was
    /// appended to rather than rewritten, and reading can resume there.
    private func tailHash(_ path: String, before offset: UInt64) -> UInt64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let n = Int(min(64, offset))
        var bytes = [UInt8](repeating: 0, count: n)
        guard pread(fd, &bytes, n, off_t(offset) - off_t(n)) == n else { return 0 }
        return Self.fnv(bytes)
    }

    // MARK: Parsing

    private func read(_ s: Source, into r: inout FileRecord) {
        let start = r.offset
        switch s.agent {
        case .claude: r.offset = readClaude(s.path, into: &r)
        case .codex: r.offset = readCodex(s.path, into: &r)
        case .cursor: break
        }
        r.size = s.size
        r.mtime = s.mtime.timeIntervalSince1970
        r.tail = tailHash(s.path, before: r.offset)
        stats.bytesRead += r.offset - start
    }

    /// Each assistant message once, by id, with the same rules as UsageTally: the
    /// last line for an id wins, sidechain lines count, escaped usage is ignored.
    private func readClaude(_ path: String, into r: inout FileRecord) -> UInt64 {
        var byID: [UInt64: Int] = [:]
        for (i, e) in r.events.enumerated() { byID[e.id] = i }
        var strings = StringTable(r.strings)
        let offset = reader.read(path, from: r.offset) { line in
            guard let hit = UsageTally.message(line) else { return }
            let top = Self.topLevel(line, wantCwd: true)
            guard let ts = top.timestamp, let time = Self.epoch(line, ts) else { return }
            let model = UsageTally.model(line).map { strings.index($0.0, line, $0.1) } ?? strings.index("unknown")
            let project = top.cwd.map { strings.index(Self.fnv(line, $0), line, $0) } ?? strings.index("")
            let e = UsageEvent(id: hit.id, time: time, model: model, project: project, usage: hit.usage)
            if let i = byID[hit.id] { r.events[i] = e } else { byID[hit.id] = r.events.count; r.events.append(e) }
        }
        r.strings = strings.strings
        return offset
    }

    private static let turnContext = [Array("\"type\":\"turn_context\"".utf8), Array("\"type\": \"turn_context\"".utf8)]
    private static let threadSettings = [Array("\"type\":\"thread_settings_applied\"".utf8), Array("\"type\": \"thread_settings_applied\"".utf8)]
    private static let totalUsage = Array("\"total_token_usage\"".utf8)
    private static let codexFields = ["\"input_tokens\"", "\"cached_input_tokens\"", "\"cache_write_input_tokens\"", "\"output_tokens\""]
        .map { Array($0.utf8) }

    /// token_count carries running totals for the thread; each event's change from
    /// the previous one is what was used at its time, under the latest model. The
    /// lines needed are a few KB; tool output lines can be over 10 MB and are skipped.
    private func readCodex(_ path: String, into r: inout FileRecord) -> UInt64 {
        var strings = StringTable(r.strings)
        let offset = reader.read(path, from: r.offset, maxLine: 1 << 20) { line in
            if Self.has(line, Self.turnContext) || Self.has(line, Self.threadSettings) {
                if let m = UsageTally.model(line) { r.codexModel = strings.index(m.0, line, m.1) + 1 }
                return
            }
            guard let at = UsageTally.find(line, Self.totalUsage),
                  let open = UsageTally.find(line, [0x7B], from: at),
                  let close = UsageTally.find(line, [0x7D], from: open) else { return }
            var total = [Int](repeating: 0, count: 4)
            for (i, key) in Self.codexFields.enumerated() {
                if let k = UsageTally.find(line, key, from: open, to: close) {
                    total[i] = UsageTally.integer(line, after: k + key.count)?.0 ?? 0
                }
            }
            guard let ts = Self.topLevel(line, wantCwd: false).timestamp, let time = Self.epoch(line, ts) else { return }
            let reset = zip(total, r.codexTotals).contains { $0 < $1 }
            let d = reset ? total : zip(total, r.codexTotals).map { $0 - $1 }
            r.codexTotals = total
            guard d.contains(where: { $0 != 0 }) else { return }
            let usage = Usage(input: max(0, d[0] - d[1] - d[2]), cacheWrite5m: d[2], cacheWrite1h: 0, cacheRead: d[1], output: d[3])
            let model = r.codexModel > 0 ? r.codexModel - 1 : strings.index("")
            r.events.append(UsageEvent(id: 0, time: time, model: model, project: strings.index(""), usage: usage))
        }
        r.strings = strings.strings
        return offset
    }

    private static func has(_ line: UnsafeRawBufferPointer, _ needles: [[UInt8]]) -> Bool {
        needles.contains { UsageTally.find(line, $0) != nil }
    }

    private static let timestampKey = Array("timestamp".utf8)
    private static let cwdKey = Array("cwd".utf8)

    /// Ranges of the top-level "timestamp" and "cwd" string values. Walks the line
    /// once, skipping strings with memchr and nested values by depth, because tool
    /// inputs inside the message can carry keys with the same names.
    static func topLevel(_ line: UnsafeRawBufferPointer, wantCwd: Bool) -> (timestamp: Range<Int>?, cwd: Range<Int>?) {
        guard let p = line.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return (nil, nil) }
        let n = line.count
        func closingQuote(_ from: Int) -> Int {
            var k = from
            while k < n, let q = memchr(p + k, 0x22, n - k) {
                let at = UnsafeRawPointer(p).distance(to: q)
                var slashes = 0
                while at - slashes - 1 >= from, p[at - slashes - 1] == 0x5C { slashes += 1 }
                if slashes % 2 == 0 { return at }
                k = at + 1
            }
            return n
        }
        func equals(_ key: [UInt8], _ start: Int, _ end: Int) -> Bool {
            end - start == key.count && key.withUnsafeBytes { memcmp(p + start, $0.baseAddress, key.count) } == 0
        }
        var timestamp: Range<Int>?, cwd: Range<Int>?
        var i = 0, depth = 0
        while i < n {
            let c = p[i]
            if c == 0x22 {
                let start = i + 1
                let end = closingQuote(start)
                i = end + 1
                guard depth == 1 else { continue }
                var j = i
                while j < n, p[j] == 0x20 { j += 1 }
                guard j < n, p[j] == 0x3A else { continue }
                j += 1
                while j < n, p[j] == 0x20 { j += 1 }
                guard j < n, p[j] == 0x22 else { continue }
                let isTime = equals(timestampKey, start, end)
                guard isTime || (wantCwd && equals(cwdKey, start, end)) else { continue }
                let valueEnd = closingQuote(j + 1)
                if isTime { timestamp = j + 1..<valueEnd } else { cwd = j + 1..<valueEnd }
                i = valueEnd + 1
                if timestamp != nil, cwd != nil || !wantCwd { break }
                continue
            }
            if c == 0x7B || c == 0x5B { depth += 1 } else if c == 0x7D || c == 0x5D { depth -= 1 }
            i += 1
        }
        return (timestamp, cwd)
    }

    /// Seconds since 1970 for 2026-10-12T15:36:01.123Z, or with a ±hh:mm offset.
    static func epoch(_ line: UnsafeRawBufferPointer, _ r: Range<Int>) -> Int64? {
        guard r.count >= 19 else { return nil }
        let b = r.lowerBound
        func num(_ at: Int, _ len: Int) -> Int? {
            var v = 0
            for k in at..<at + len {
                let c = line[b + k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard line[b + 4] == 0x2D, line[b + 7] == 0x2D, line[b + 10] == 0x54 || line[b + 10] == 0x20,
              line[b + 13] == 0x3A, line[b + 16] == 0x3A,
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var k = 19
        while k < r.count, line[b + k] == 0x2E || (line[b + k] >= 0x30 && line[b + k] <= 0x39) { k += 1 }
        var offset = 0
        if k < r.count, line[b + k] == 0x2B || line[b + k] == 0x2D, r.count - k >= 5, let oh = num(k + 1, 2) {
            let om = line[b + k + 3] == 0x3A ? num(k + 4, 2) : num(k + 3, 2)
            offset = (oh * 3600 + (om ?? 0) * 60) * (line[b + k] == 0x2D ? -1 : 1)
        }
        // Days from 1970-01-01 to the civil date (Howard Hinnant's algorithm).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Int64(days * 86_400 + h * 3600 + mi * 60 + s - offset)
    }

    static func fnv<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var h: UInt64 = 0xcbf29ce484222325
        for c in bytes { h = (h ^ UInt64(c)) &* 0x100000001b3 }
        return h
    }

    private static func fnv(_ line: UnsafeRawBufferPointer, _ r: Range<Int>) -> UInt64 {
        fnv(UnsafeRawBufferPointer(rebasing: line[r]))
    }
}

// MARK: - Per-file records

/// One assistant message (Claude) or one token_count change (Codex).
struct UsageEvent {
    var id: UInt64               // message id hash; 0 when there is nothing to dedupe
    var time: Int64              // seconds since 1970
    var model: Int               // index into the file's strings
    var project: Int
    var usage: Usage
}

/// Everything a scan keeps about one file, enough to resume reading it.
struct FileRecord {
    var path: String
    var agent: Agent
    var size: UInt64 = 0
    var mtime: Double = 0
    var offset: UInt64 = 0       // bytes read, through the last complete line
    var tail: UInt64 = 0         // hash of the bytes before `offset`
    var codexTotals = [0, 0, 0, 0]
    var codexModel = 0           // index + 1 into strings, 0 before any model is named
    var strings: [String] = []
    var events: [UsageEvent] = []

    init(path: String, agent: Agent) {
        self.path = path
        self.agent = agent
    }

    init?(decoding body: UnsafeRawBufferPointer, headerOnly: Bool = false) {
        var c = ByteCursor(body)
        guard let path = c.string(), let size = c.varint(), let mtime = c.u64(), let agent = c.varint(),
              let offset = c.varint(), let tail = c.u64() else { return nil }
        self.init(path: path, agent: agent == 1 ? .codex : .claude)
        self.size = size
        self.mtime = Double(bitPattern: mtime)
        self.offset = offset
        self.tail = tail
        if headerOnly { return }
        for i in 0..<4 { guard let v = c.varint() else { return nil }; codexTotals[i] = Int(v) }
        guard let model = c.varint(), let nStrings = c.varint() else { return nil }
        codexModel = Int(model)
        for _ in 0..<nStrings { guard let s = c.string() else { return nil }; strings.append(s) }
        guard let nEvents = c.varint() else { return nil }
        events.reserveCapacity(Int(nEvents))
        var time: Int64 = 0
        for _ in 0..<nEvents {
            guard let id = c.u64(), let dt = c.varint(), let m = c.varint(), let p = c.varint(),
                  let a = c.varint(), let b = c.varint(), let h = c.varint(), let r = c.varint(), let o = c.varint(),
                  Int(m) < strings.count, Int(p) < strings.count else { return nil }
            time += Int64(bitPattern: (dt >> 1) ^ (0 &- (dt & 1)))
            events.append(UsageEvent(id: id, time: time, model: Int(m), project: Int(p),
                                     usage: Usage(input: Int(a), cacheWrite5m: Int(b), cacheWrite1h: Int(h), cacheRead: Int(r), output: Int(o))))
        }
    }

    func encoded() -> Data {
        var w = ByteWriter()
        w.string(path)
        w.varint(size)
        w.u64(mtime.bitPattern)
        w.varint(agent == .codex ? 1 : 0)
        w.varint(offset)
        w.u64(tail)
        codexTotals.forEach { w.varint(UInt64(max(0, $0))) }
        w.varint(UInt64(codexModel))
        w.varint(UInt64(strings.count))
        strings.forEach { w.string($0) }
        w.varint(UInt64(events.count))
        var time: Int64 = 0
        for e in events {
            let dt = e.time - time
            time = e.time
            w.u64(e.id)
            w.varint(UInt64(bitPattern: (dt << 1) ^ (dt >> 63)))
            w.varint(UInt64(e.model))
            w.varint(UInt64(e.project))
            for v in [e.usage.input, e.usage.cacheWrite5m, e.usage.cacheWrite1h, e.usage.cacheRead, e.usage.output] {
                w.varint(UInt64(max(0, v)))
            }
        }
        return w.data
    }
}

/// Interns strings by the FNV-1a hash of their bytes, creating each String once.
private struct StringTable {
    private(set) var strings: [String]
    private var index: [UInt64: Int] = [:]

    init(_ strings: [String]) {
        self.strings = strings
        for (i, s) in strings.enumerated() { index[History.fnv(s.utf8)] = i }
    }

    /// A JSON string value by the hash of its raw bytes, unescaped when first seen.
    mutating func index(_ hash: UInt64, _ line: UnsafeRawBufferPointer, _ range: Range<Int>) -> Int {
        if let i = index[hash] { return i }
        let raw = UnsafeRawBufferPointer(rebasing: line[range])
        guard raw.contains(0x5C) else { return add(String(decoding: raw, as: UTF8.self), hash) }
        let literal = Data([0x22]) + Data(raw) + Data([0x22])
        let s = (try? JSONSerialization.jsonObject(with: literal, options: .fragmentsAllowed)) as? String
        return add(s ?? String(decoding: raw, as: UTF8.self), hash)
    }

    mutating func index(_ s: String) -> Int {
        let hash = History.fnv(s.utf8)
        return index[hash] ?? add(s, hash)
    }

    private mutating func add(_ s: String, _ hash: UInt64) -> Int {
        strings.append(s)
        index[hash] = strings.count - 1
        return strings.count - 1
    }
}

// MARK: - Totals

/// Sums events into (day, agent, model, project) cells, counting each message id
/// once across files: resumed and forked sessions copy earlier messages verbatim.
private struct Totals {
    struct Key: Hashable { var day: Int; var agent: Agent; var model: Int; var project: Int }

    let window: DayWindow
    var cells: [Key: Usage] = [:]
    var models = Interner()
    var projects = Interner()
    var seen = Set<UInt64>()

    init(window: DayWindow) { self.window = window }

    mutating func add(_ r: FileRecord, _ s: History.Source) {
        var model: [Int?] = Array(repeating: nil, count: r.strings.count)
        var project: [Int?] = Array(repeating: nil, count: r.strings.count)
        for e in r.events {
            guard let day = window.day(e.time) else { continue }
            if e.id != 0, !seen.insert(e.id).inserted { continue }
            if model[e.model] == nil {
                let name = r.strings[e.model]
                model[e.model] = models.index(name.isEmpty ? (s.model.isEmpty ? "unknown" : s.model) : name)
            }
            if project[e.project] == nil {
                let cwd = s.agent == .codex ? s.project : r.strings[e.project]
                project[e.project] = projects.index(cwd.isEmpty && s.agent == .claude ? "folder:" + s.project : cwd)
            }
            cells[Key(day: day, agent: s.agent, model: model[e.model]!, project: project[e.project]!), default: Usage()] += e.usage
        }
    }

    mutating func add(day: Int, agent: Agent, model: String, project: String, usage: Usage) {
        cells[Key(day: day, agent: agent, model: models.index(model), project: projects.index(project)), default: Usage()] += usage
    }

    func history() -> UsageHistory {
        var days = window.starts.map { UsageHistory.Day(start: Date(timeIntervalSince1970: TimeInterval($0))) }
        var byModel: [Int: UsageHistory.Row] = [:]
        var byProject: [Int: UsageHistory.Row] = [:]
        for (k, u) in cells where u.total > 0 {
            let name = models.strings[k.model]
            let cost = Pricing.cost(u, model: name)
            days[k.day].tokens[k.agent, default: 0] += u.total
            if let cost { days[k.day].cost[k.agent, default: 0] += cost }
            func fold(_ row: inout UsageHistory.Row) {
                if row.tokens == 0 { row.agent = k.agent } else if row.agent != k.agent { row.agent = nil }
                row.tokens += u.total
                row.cost += cost ?? 0
                if cost == nil { row.unpriced = true }
            }
            fold(&byModel[k.model, default: UsageHistory.Row(id: name, name: name)])
            let path = projects.strings[k.project]
            fold(&byProject[k.project, default: UsageHistory.Row(id: path, name: Self.projectName(path))])
        }
        let order = { (a: UsageHistory.Row, b: UsageHistory.Row) in a.tokens != b.tokens ? a.tokens > b.tokens : a.id < b.id }
        return UsageHistory(days: days, models: byModel.values.sorted(by: order), projects: byProject.values.sorted(by: order))
    }

    /// The folder's name; for a Claude project folder (the path with separators
    /// turned into '-'), what follows the home folder.
    static func projectName(_ key: String) -> String {
        if key.isEmpty { return "Unknown" }
        guard key.hasPrefix("folder:") else { return (key as NSString).lastPathComponent }
        let folder = String(key.dropFirst(7))
        let homePrefix = home.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-") + "-"
        return folder.hasPrefix(homePrefix) ? String(folder.dropFirst(homePrefix.count)) : folder
    }
}

private struct Interner {
    private(set) var strings: [String] = []
    private var index: [String: Int] = [:]

    mutating func index(_ s: String) -> Int {
        if let i = index[s] { return i }
        strings.append(s)
        index[s] = strings.count - 1
        return strings.count - 1
    }
}

// MARK: - Cache file

/// usage-cache.bin: a magic number and version, then length-prefixed file records.
/// Mapped, not read, so an unchanged cache costs no dirty memory. Record pointers
/// are valid while this object lives.
private final class CacheFile {
    static let magic: [UInt8] = Array("MUSG".utf8)
    private let data: NSData?
    private(set) var records: [String: UnsafeRawBufferPointer] = [:]

    init(path: String) {
        data = try? NSData(contentsOfFile: path, options: .alwaysMapped)
        guard let data, data.length >= 5 else { return }
        var c = ByteCursor(UnsafeRawBufferPointer(start: data.bytes, count: data.length))
        guard c.bytes(4).map(Array.init) == Self.magic, c.varint() == History.cacheVersion else { return }
        while let length = c.varint(), let body = c.bytes(Int(length)) {
            var head = ByteCursor(body)
            if let path = head.string() { records[path] = body }
        }
    }
}

/// Writes the next cache beside the current one and swaps it in when done.
private final class CacheWriter {
    private let path: String
    private let temp: String
    private let handle: FileHandle?
    private var buffer = ByteWriter()

    init(path: String) {
        self.path = path
        temp = path + ".\(getpid()).tmp"
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        handle = FileManager.default.createFile(atPath: temp, contents: nil) ? FileHandle(forWritingAtPath: temp) : nil
        buffer.data.append(contentsOf: CacheFile.magic)
        buffer.varint(History.cacheVersion)
    }

    func append(_ body: UnsafeRawBufferPointer) {
        buffer.varint(UInt64(body.count))
        buffer.data.append(contentsOf: body)
        flushIfFull()
    }

    func append(_ body: Data) {
        buffer.varint(UInt64(body.count))
        buffer.data.append(body)
        flushIfFull()
    }

    private func flushIfFull() {
        guard buffer.data.count >= 256 << 10 else { return }
        handle?.write(buffer.data)
        buffer.data.removeAll(keepingCapacity: true)
    }

    func finish() {
        guard let handle else { return }
        handle.write(buffer.data)
        try? handle.close()
        rename(temp, path)
    }
}

private struct ByteWriter {
    var data = Data()

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }

    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

    mutating func string(_ s: String) {
        let bytes = Array(s.utf8)
        varint(UInt64(bytes.count))
        data.append(contentsOf: bytes)
    }
}

private struct ByteCursor {
    let raw: UnsafeRawBufferPointer
    var at = 0

    init(_ raw: UnsafeRawBufferPointer) { self.raw = raw }

    mutating func varint() -> UInt64? {
        var v: UInt64 = 0, shift: UInt64 = 0
        while at < raw.count, shift < 64 {
            let b = raw[at]
            at += 1
            v |= UInt64(b & 0x7F) << shift
            if b < 0x80 { return v }
            shift += 7
        }
        return nil
    }

    mutating func u64() -> UInt64? {
        guard at + 8 <= raw.count else { return nil }
        let v = raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)
        at += 8
        return UInt64(littleEndian: v)
    }

    mutating func bytes(_ n: Int) -> UnsafeRawBufferPointer? {
        guard n >= 0, at + n <= raw.count else { return nil }
        defer { at += n }
        return UnsafeRawBufferPointer(rebasing: raw[at..<at + n])
    }

    mutating func string() -> String? {
        guard let n = varint(), let b = bytes(Int(n)) else { return nil }
        return String(decoding: b, as: UTF8.self)
    }
}

// MARK: - Demo

extension UsageHistory {
    /// Illustrative history for screenshots (`--demo`), from the same sample
    /// projects and models as Session.samples. The same every time.
    static func sample(now: Date = Date()) -> UsageHistory {
        let window = DayWindow(now: now)
        var totals = Totals(window: window)
        let mix: [(Agent, String, String, Double)] = [
            (.claude, "claude-opus-5-5", "/work/atlas", 64),
            (.claude, "claude-sonnet-5", "/work/atlas", 46),
            (.claude, "claude-opus-5-5", "/work/media", 30),
            (.codex, "gpt-6-astra", "/work/lexer", 9),
            (.codex, "gpt-6.1-sol", "/work/docs", 4),
        ]
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let calendar = Calendar.current
        for (day, start) in window.starts.enumerated() {
            let weekday = calendar.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(start)))
            let pace = (weekday == 1 || weekday == 7 ? 0.25 : 1) * (0.6 + 0.4 * Double(day) / Double(History.days))
            for (agent, model, project, millions) in mix {
                let t = millions * 1_000_000 * pace * (0.55 + 0.9 * next())
                totals.add(day: day, agent: agent, model: model, project: project,
                           usage: Usage(input: Int(t * 0.0004), cacheWrite5m: Int(t * 0.012), cacheWrite1h: Int(t * 0.018),
                                        cacheRead: Int(t * 0.965), output: Int(t * 0.0046)))
            }
        }
        return totals.history()
    }
}
