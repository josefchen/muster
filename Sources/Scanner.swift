import Foundation
import SQLite3

// Reads live agent sessions straight from the files each app already writes, the
// same files their own windows render from. No hooks, no network.
//
// Agents append to their transcripts many times a second, so a scan must cost
// next to nothing when little changed: directories are re-read only when FSEvents
// names them, transcripts are read only from where the last scan stopped, and the
// apps' databases stay open between queries.

/// Your home folder. End-to-end runs (MUSTER_E2E=1) read a fixture folder from
/// MUSTER_HOME instead; E2E.swift refuses to start if that could be the real one.
let home: String = {
    let env = ProcessInfo.processInfo.environment
    if env["MUSTER_E2E"] == "1", let fixture = env["MUSTER_HOME"] { return fixture }
    return FileManager.default.homeDirectoryForCurrentUser.path
}()
let recentWindow: TimeInterval = 3 * 3600   // files untouched for longer are not read

// MARK: - Changes

/// What changed on disk since the last scan, as FSEvents reports it: the directories
/// whose entries or files changed. Readers re-read only those and keep everything
/// else from memory; `full` re-reads everything.
struct Changes {
    var full = false
    private(set) var dirs: Set<String> = []
    private(set) var trees: [String] = []

    static let all = Changes(full: true)

    var isEmpty: Bool { !full && dirs.isEmpty && trees.isEmpty }

    /// A directory FSEvents named; `subtree` when it asks for everything below it too.
    mutating func add(_ path: String, subtree: Bool = false) {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if subtree { trees.append(p) } else { dirs.insert(p) }
    }

    func touches(_ dir: String) -> Bool {
        full || dirs.contains(dir) || trees.contains { dir == $0 || dir.hasPrefix($0 + "/") }
    }
}

// MARK: - Files

struct FileInfo: Equatable {
    let path: String
    let size: UInt64
    let mtime: Date
    var ino: UInt64 = 0
    var birth: TimeInterval = 0
    var ctime: TimeInterval = 0   // changes with permissions too

    /// The same file with the same bytes, as far as its metadata can tell.
    func same(_ o: FileInfo?) -> Bool { o.map { $0.size == size && $0.mtime == mtime && $0.ino == ino } ?? false }
}

/// POSIX stat: Foundation's attributesOfItem builds a dictionary per call, which
/// dominated rescans across hundreds of transcripts.
func stat(_ path: String) -> FileInfo? {
    var st = Darwin.stat()
    guard fstatat(AT_FDCWD, path, &st, 0) == 0 else { return nil }
    func seconds(_ t: timespec) -> TimeInterval { TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9 }
    return FileInfo(path: path, size: UInt64(st.st_size), mtime: Date(timeIntervalSince1970: seconds(st.st_mtimespec)),
                    ino: UInt64(st.st_ino), birth: seconds(st.st_birthtimespec), ctime: seconds(st.st_ctimespec))
}

/// The path with symlinks resolved, which is how FSEvents names it (/var → /private/var).
func canonical(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

func parent(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
    return String(path[..<slash])
}

/// A directory's entries via readdir: Foundation's listing builds a URL and an
/// attribute dictionary per entry, which was half of every scan.
func entries(_ dir: String) -> [(name: String, isDir: Bool)]? {
    guard let d = opendir(dir) else { return nil }
    defer { closedir(d) }
    var out: [(name: String, isDir: Bool)] = []
    while let e = readdir(d) {
        let length = Int(e.pointee.d_namlen)
        let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
        if name == "." || name == ".." { continue }
        let type = Int32(e.pointee.d_type)
        var isDir = type == DT_DIR
        if type == DT_UNKNOWN || type == DT_LNK {
            var st = Darwin.stat()
            isDir = fstatat(AT_FDCWD, dir + "/" + name, &st, 0) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        }
        out.append((name, isDir))
    }
    return out
}

/// A directory's paths, for walking a whole tree once (the Usage window).
func list(_ dir: String) -> [String] {
    let base = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
    return (entries(base) ?? []).map { base + "/" + $0.name }
}

/// Directory listings and file metadata, re-read one directory at a time: only the
/// directories FSEvents named since the last scan, or every one on a full pass. A
/// scan with nothing new makes no system calls here beyond one stat per root.
final class DirTree {
    struct Node {
        fileprivate var stamp = Stamp()
        fileprivate var parent = ""
        fileprivate var names: [String] = []
        var exists = false
        var dirs: [String] = []
        var files: [(name: String, info: FileInfo)] = []
    }

    /// What a directory's own metadata says: entries come and go with mtime, and
    /// permissions change ctime.
    fileprivate struct Stamp: Equatable {
        var mtime = 0, mtimeNs = 0, ctime = 0, ctimeNs = 0
        var ino: UInt64 = 0

        init() {}
        init(_ st: Darwin.stat) {
            mtime = st.st_mtimespec.tv_sec
            mtimeNs = st.st_mtimespec.tv_nsec
            ctime = st.st_ctimespec.tv_sec
            ctimeNs = st.st_ctimespec.tv_nsec
            ino = UInt64(st.st_ino)
        }
    }

    private var nodes: [String: Node] = [:]
    private var visited: Set<String>?

    /// A full pass forgets the directories it no longer reaches.
    func begin(_ changes: Changes) { visited = changes.full ? [] : nil }

    func end() {
        if let visited, visited.count < nodes.count { nodes = nodes.filter { visited.contains($0.key) } }
        visited = nil
    }

    /// `dir`'s subdirectories and the files `want` picks, with their metadata, or nil
    /// if it's missing or unreadable. Re-read when `changes` names it or its parent:
    /// FSEvents reports a folder's permission change, or its creation, to the parent.
    /// A `root` is the watched folder itself, whose own changes FSEvents never
    /// reports, so it is checked with one stat every time.
    func node(_ dir: String, _ changes: Changes, root: Bool = false, want: (String) -> Bool) -> Node? {
        visited?.insert(dir)
        if let n = nodes[dir], !changes.touches(dir), n.parent.isEmpty || !changes.touches(n.parent) {
            guard root else { return n.exists ? n : nil }
            var st = Darwin.stat()
            let now = fstatat(AT_FDCWD, dir, &st, 0) == 0 ? Stamp(st) : Stamp()
            if now == n.stamp { return n.exists ? n : nil }
        }
        var n = read(dir, old: nodes[dir], want: want)
        n.parent = root ? "" : parent(dir)
        nodes[dir] = n
        return n.exists ? n : nil
    }

    private func read(_ dir: String, old: Node?, want: (String) -> Bool) -> Node {
        var st = Darwin.stat()
        guard fstatat(AT_FDCWD, dir, &st, 0) == 0 else { return Node() }
        var n = Node()
        n.stamp = Stamp(st)
        guard (st.st_mode & S_IFMT) == S_IFDIR, access(dir, R_OK | X_OK) == 0 else { return n }
        n.exists = true
        if let old, old.exists, old.stamp.mtime == n.stamp.mtime, old.stamp.mtimeNs == n.stamp.mtimeNs, old.stamp.ino == n.stamp.ino {
            // Only file contents changed: the names are the same, the metadata isn't.
            n.dirs = old.dirs
            n.names = old.names
        } else {
            guard let list = entries(dir) else { return Node() }
            for e in list {
                if e.isDir { n.dirs.append(e.name) } else if want(e.name) { n.names.append(e.name) }
            }
        }
        n.files = n.names.compactMap { name in stat(dir + "/" + name).map { (name, $0) } }
        return n
    }
}

/// Re-parse a file only when its size or modification time changed.
final class FileCache<Value> {
    private var entries: [String: (UInt64, Date, Value)] = [:]
    private var used: Set<String> = []

    func value(_ path: String, size: UInt64, mtime: Date, parse: (String) -> Value) -> Value {
        used.insert(path)
        if let e = entries[path], e.0 == size, e.1 == mtime { return e.2 }
        let v = parse(path)
        entries[path] = (size, mtime, v)
        return v
    }

    /// Forgets the files not asked for since the last sweep.
    func sweep() {
        if used.count < entries.count { entries = entries.filter { used.contains($0.key) } }
        used = []
    }
}

// MARK: - Reading lines

/// One buffer for reading transcripts backward, shared by the live readers: all
/// scanning runs on one serial queue, and a buffer per reader, or a fresh one per
/// read, left megabytes dirty for good.
final class ReadBuffer {
    static let shared = ReadBuffer()
    private static let base = 256 << 10

    private(set) var bytes = UnsafeMutableRawPointer.allocate(byteCount: base, alignment: 16)
    private(set) var capacity = base

    deinit { bytes.deallocate() }

    func reserve(_ count: Int, keeping: Int = 0) {
        guard count > capacity else { return }
        var c = capacity
        while c < count { c *= 2 }
        let bigger = UnsafeMutableRawPointer.allocate(byteCount: c, alignment: 16)
        if keeping > 0 { bigger.copyMemory(from: bytes, byteCount: keeping) }
        bytes.deallocate()
        bytes = bigger
        capacity = c
    }

    /// Back to the base size after a long line made it grow.
    func shrink() {
        guard capacity > 4 * Self.base else { return }
        bytes.deallocate()
        bytes = UnsafeMutableRawPointer.allocate(byteCount: Self.base, alignment: 16)
        capacity = Self.base
    }

    /// Exactly `count` bytes from `offset`, or false if the file is shorter.
    func fill(_ fd: Int32, at offset: UInt64, count: Int) -> Bool {
        reserve(count)
        var got = 0
        while got < count {
            let n = pread(fd, bytes + got, count - got, off_t(offset) + off_t(got))
            if n <= 0 { return false }
            got += n
        }
        return true
    }
}

/// Reads complete lines through one reused buffer: allocating a fresh chunk per
/// read leaves the allocator caching freed megabytes.
final class LineReader {
    private let baseCapacity: Int
    private var buffer: UnsafeMutableRawPointer
    private var capacity: Int

    /// The live tally reads small appends and keeps a small buffer; the Usage window
    /// reads gigabytes and keeps a larger one.
    init(capacity: Int = 1 << 20) {
        baseCapacity = capacity
        self.capacity = capacity
        buffer = malloc(capacity)!
    }

    deinit { free(buffer) }

    /// Each complete line from `offset` on, without its newline. Returns the offset
    /// after the last newline, so a line still being written is read next time.
    /// Lines longer than `maxLine` are skipped without being buffered whole.
    func read(_ path: String, from offset: UInt64, maxLine: Int = .max,
              _ body: (UnsafeRawBufferPointer) -> Void) -> UInt64 {
        var offset = offset
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return offset }
        defer { close(fd) }
        lseek(fd, off_t(offset), SEEK_SET)
        var filled = 0
        var skipping = false
        var skipped: UInt64 = 0
        while true {
            if filled == capacity {
                if capacity >= maxLine {
                    skipping = true
                    skipped += UInt64(filled)
                    filled = 0
                } else {
                    grow()
                }
            }
            let n = Darwin.read(fd, buffer + filled, capacity - filled)
            if n <= 0 { break }
            filled += n
            var start = 0
            while start < filled, let nl = memchr(buffer + start, 0x0A, filled - start) {
                let end = buffer.distance(to: nl)
                if skipping { skipping = false } else { body(UnsafeRawBufferPointer(start: buffer + start, count: end - start)) }
                start = end + 1
            }
            if start > 0 {
                offset += skipped + UInt64(start)
                skipped = 0
            }
            memmove(buffer, buffer + start, filled - start)
            filled -= start
        }
        if capacity > 4 * baseCapacity { shrink() }
        return offset
    }

    /// realloc can extend in place, so a long line never holds two buffers at once.
    private func grow() {
        capacity *= 2
        buffer = realloc(buffer, capacity)!
    }

    private func shrink() {
        free(buffer)
        buffer = malloc(baseCapacity)!
        capacity = baseCapacity
    }

    /// The lines in [from, to) of `fd`, newest first, until `body` returns false. Reads
    /// backward through a window that grows (×4, up to `maxLine`) to hold a long line,
    /// asking `grow` before going further back, so finding something near the end never
    /// touches older bytes. A line longer than `maxLine` (one giant tool result) is never
    /// loaded: its start is found by scanning back block by block, `oversized` sees its
    /// first 64 KB, and the lines before it are read as usual. With `trailing`, a last
    /// line with no newline yet is offered too. Returns the offset just past the last
    /// newline (`from` if there is none): where the next incremental read starts.
    static func reverse(_ fd: Int32, from: UInt64, to: UInt64, trailing: Bool = true, maxLine: Int = 8 << 20,
                        buffer: ReadBuffer = .shared, grow: () -> Bool = { true },
                        oversized: (UnsafeRawBufferPointer) -> Bool = { _ in true },
                        _ body: (UnsafeRawBufferPointer) -> Bool) -> UInt64 {
        guard to > from else { return from }
        defer { buffer.shrink() }
        func head(_ at: UInt64) -> Bool {
            var bytes = [UInt8](repeating: 0, count: 64 << 10)
            let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(at)) }
            return bytes.withUnsafeBytes { oversized(UnsafeRawBufferPointer(rebasing: $0[..<max(0, n)])) }
        }
        var window = 256 << 10
        var end: UInt64?          // just past the region's last newline, once found
        var hi = to               // the next line to visit ends here: at a newline, or at `to`
        var skipping = false      // that line is longer than `maxLine`; its start is being looked for
        while true {
            let lo = hi - min(UInt64(window), hi - from)
            let count = Int(hi - lo)
            guard count > 0, buffer.fill(fd, at: lo, count: count) else { return end ?? from }
            let p = buffer.bytes
            func line(_ a: Int, _ b: Int) -> UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: p + a, count: b - a) }
            var j = count
            while let k = Self.newline(p, below: j) {
                let start = lo + UInt64(k) + 1
                if end == nil {
                    end = start
                    if trailing, !skipping, k + 1 < j, !body(line(k + 1, j)) { return start }
                } else if skipping {
                    if !head(start) { return end! }
                } else if k + 1 < j, !body(line(k + 1, j)) {
                    return end!
                }
                skipping = false
                j = k
            }
            if lo == from {
                // What is left is the region's first line.
                guard let end else {
                    if trailing, !skipping, j > 0 { _ = body(line(0, j)) }
                    return from
                }
                if skipping { _ = head(from) } else if j > 0 { _ = body(line(0, j)) }
                return end
            }
            guard grow() else { return end ?? from }
            if !skipping, j == count, window >= maxLine { skipping = true }
            if skipping {
                hi = lo                   // all of this window belongs to the long line
                window = 1 << 20
            } else {
                hi = lo + UInt64(j)       // the line that started below the window ends here
                if j == count { window = min(window * 4, maxLine) }
            }
        }
    }

    private static func newline(_ p: UnsafeMutableRawPointer, below j: Int) -> Int? {
        var k = j - 1
        while k >= 0 {
            if p.load(fromByteOffset: k, as: UInt8.self) == 0x0A { return k }
            k -= 1
        }
        return nil
    }

    /// The first line of a file (up to 4 MB), for a title that never changes.
    static func first<T>(_ path: String, _ body: (UnsafeRawBufferPointer) -> T?) -> T? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let buffer = ReadBuffer.shared
        defer { buffer.shrink() }
        var filled = 0
        while filled < 4 << 20 {
            buffer.reserve(filled + (64 << 10), keeping: filled)
            let n = pread(fd, buffer.bytes + filled, 64 << 10, off_t(filled))
            if n <= 0 { break }
            if let nl = memchr(buffer.bytes + filled, 0x0A, n) {
                return body(UnsafeRawBufferPointer(start: buffer.bytes, count: buffer.bytes.distance(to: nl)))
            }
            filled += n
        }
        return body(UnsafeRawBufferPointer(start: buffer.bytes, count: filled))
    }
}

// MARK: - JSON bytes

enum Bytes {
    static func has(_ line: UnsafeRawBufferPointer, _ needles: [[UInt8]]) -> Bool {
        needles.contains { UsageTally.find(line, $0) != nil }
    }

    /// Index just past the string whose opening quote is at `from - 1`.
    static func skipString(_ b: UnsafeRawBufferPointer, from: Int) -> Int {
        guard let base = b.baseAddress else { return b.count }
        var i = from
        while i < b.count {
            guard let q = memchr(base + i, 0x22, b.count - i) else { return b.count }
            let k = base.distance(to: q)
            var slashes = 0
            while k - slashes - 1 >= from, b[k - slashes - 1] == 0x5C { slashes += 1 }
            if slashes % 2 == 0 { return k + 1 }
            i = k + 1
        }
        return b.count
    }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }

    /// A JSON string literal (quotes included) as a String.
    static func string(_ b: UnsafeRawBufferPointer, _ r: Range<Int>) -> String? {
        guard r.count >= 2, b[r.lowerBound] == 0x22 else { return nil }
        let inner = UnsafeRawBufferPointer(rebasing: b[r.lowerBound + 1..<r.upperBound - 1])
        guard let base = inner.baseAddress, !inner.isEmpty else { return "" }
        if memchr(base, 0x5C, inner.count) == nil { return String(decoding: inner, as: UTF8.self) }
        return (try? JSONSerialization.jsonObject(with: Data(UnsafeRawBufferPointer(rebasing: b[r])), options: .fragmentsAllowed)) as? String
    }
}

/// The top-level fields of one JSON object, read straight from its bytes: nested
/// values are skipped (strings with memchr) and nothing is decoded unless asked for,
/// so a multi-megabyte tool result costs one pass over its bytes, not a parse.
struct TopLevel {
    let line: UnsafeRawBufferPointer
    private(set) var values: [Range<Int>?]
    private(set) var complete = false   // one whole object: not a line still being written, nor two spliced together

    init(_ line: UnsafeRawBufferPointer, _ keys: [[UInt8]]) {
        self.line = line
        values = Array(repeating: nil, count: keys.count)
        let b = line, n = line.count
        var i = 0, depth = 0
        while i < n {
            let c = b[i]
            if c == 0x22 {
                let start = i
                i = Bytes.skipString(b, from: i + 1)
                guard depth == 1 else { continue }
                let length = i - start - 2
                var j = i
                while j < n, Bytes.isSpace(b[j]) { j += 1 }
                guard j < n, b[j] == 0x3A else { continue }
                j += 1
                while j < n, Bytes.isSpace(b[j]) { j += 1 }
                i = j
                guard j < n, let k = keys.firstIndex(where: { key in
                    key.count == length && key.withUnsafeBytes { memcmp(b.baseAddress! + start + 1, $0.baseAddress!, length) } == 0
                }) else { continue }
                switch b[j] {
                case 0x22:
                    let e = Bytes.skipString(b, from: j + 1)
                    values[k] = j..<e
                    i = e
                case 0x7B, 0x5B:
                    values[k] = j..<j + 1   // present; walked below
                default:
                    var e = j
                    while e < n, b[e] != 0x2C, b[e] != 0x7D, !Bytes.isSpace(b[e]) { e += 1 }
                    values[k] = j..<e
                    i = e
                }
                continue
            }
            if c == 0x7B || c == 0x5B {
                depth += 1
            } else if c == 0x7D || c == 0x5D {
                depth -= 1
                if depth == 0 {
                    var e = i + 1
                    while e < n, Bytes.isSpace(b[e]) { e += 1 }
                    complete = c == 0x7D && e == n
                    return
                }
            }
            i += 1
        }
    }

    func string(_ k: Int) -> String? { values[k].flatMap { Bytes.string(line, $0) } }

    func bool(_ k: Int) -> Bool? {
        guard let r = values[k] else { return nil }
        switch line[r.lowerBound] {
        case 0x74: return true
        case 0x66: return false
        default: return nil
        }
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

func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
}

// MARK: - Token usage

/// Token totals for the Claude transcripts of the sessions on screen, per session and
/// model, with every API message billed exactly once:
///
/// - A resumed session's file starts with the history it continues, still marked with
///   the session that wrote it. Those lines are skipped: the other session bills them.
/// - A message that two sessions both claim as their own (Claude.app keeps writing the
///   old transcript for a while after compacting into a new one), or that sits in two
///   copies of one subagent transcript, is billed once, to the session that started first.
/// - Subagent transcripts bill to the session that spawned them.
///
/// The Usage window (History) dedupes the same 64-bit id hashes across files; here
/// each message also needs the session it belongs to, hence the rules above.
///
/// Each scan reads only the lines appended since the last one (transcripts reach
/// hundreds of MB) and decodes nothing: numbers are read straight from the bytes,
/// messages are keyed by a 64-bit hash of their id, models by a small index. Per
/// message only its owner is kept; usage lives in running totals per file.
final class UsageTally {
    private final class Tracked {
        let slot: Int
        let path: String
        let session: String
        let own: [[UInt8]]                // "sessionId":"<session>", both spacings
        var stat: FileInfo                // as of this scan
        var read: FileInfo?               // as of the last read; nil reads from the start
        var offset: UInt64 = 0
        var tail: UInt64 = 0              // hash of the bytes before `offset`
        var start: Int64 = 0              // first top-level timestamp, seconds since 1970; 0 until seen
        var totals: [UInt16: Usage] = [:]
        var pending: (id: UInt64, model: UInt16, usage: Usage)?   // the last message may still grow
        var used = true

        init(slot: Int, path: String, session: String, stat: FileInfo) {
            self.slot = slot
            self.path = path
            self.session = session
            self.stat = stat
            own = ["\"sessionId\":\"", "\"sessionId\": \""].map { Array(($0 + session + "\"").utf8) }
        }
    }

    private var tracked: [String: Tracked] = [:]
    private var slots: [Tracked?] = []
    private var free: [Int] = []
    private var owners: [UInt64: Int32] = [:]        // message → the file that bills it
    private var losers: [Int: Set<Int>] = [:]        // file → files that skipped messages it owns
    private var stale: Set<Int> = []                 // files to forget and read again
    private var models: [String] = []
    private var modelIndex: [UInt64: UInt16] = [:]
    private var sessions: [String: [UInt16: Usage]] = [:]
    private var changed = true
    private let reader = LineReader(capacity: 256 << 10)

    func begin() {
        for t in tracked.values { t.used = false }
    }

    /// Bills `f` to `session`, reading whatever it gained since the last scan.
    func add(_ f: FileInfo, session: String) {
        if let t = tracked[f.path], t.session == session {
            t.used = true
            t.stat = f
            guard !f.same(t.read) else { return }
            if let r = t.read, f.ino != r.ino || f.size < t.offset || Self.tail(f.path, before: t.offset) != t.tail {
                clear(t)   // replaced or rewritten, not appended to
            }
            if !stale.contains(t.slot) { read(t) }
            return
        }
        if let old = tracked[f.path] { old.used = false; clear(old); tracked[f.path] = nil }
        let slot = free.popLast() ?? slots.count
        if slot == slots.count { slots.append(nil) }
        let t = Tracked(slot: slot, path: f.path, session: session, stat: f)
        tracked[f.path] = t
        slots[slot] = t
        read(t)
    }

    /// Forgets the files not added this scan and re-reads those that lost a message.
    func end() {
        for t in tracked.values where !t.used { clear(t) }
        while !stale.isEmpty {
            let purge = stale
            stale = []
            owners = owners.filter { !purge.contains(Int($0.value)) }
            for s in purge {
                guard let t = slots[s] else { continue }
                if t.used {
                    if !stale.contains(s) { read(t) }   // otherwise read on the next round
                } else {
                    if tracked[t.path] === t { tracked[t.path] = nil }
                    slots[s] = nil
                    free.append(s)
                }
            }
        }
        guard changed else { return }
        changed = false
        sessions = [:]
        for t in tracked.values {
            var s = sessions[t.session] ?? [:]
            for (m, u) in t.totals { s[m, default: Usage()] += u }
            if let p = t.pending { s[p.model, default: Usage()] += p.usage }
            sessions[t.session] = s
        }
    }

    /// Usage by model for a session, as of the last `end()`.
    func usage(of session: String) -> [String: Usage] {
        var out: [String: Usage] = [:]
        for (m, u) in sessions[session] ?? [:] { out[models[Int(m)], default: Usage()] += u }
        return out
    }

    private func read(_ t: Tracked) {
        changed = true
        t.offset = reader.read(t.path, from: t.offset, maxLine: 8 << 20) { line in self.line(line, t) }   // no message line is near 8 MB
        t.tail = Self.tail(t.path, before: t.offset)
        t.read = t.stat
    }

    /// FNV-1a of up to 64 bytes before `offset`: while they match, the file was only
    /// appended to and reading can resume there (the Usage window checks the same way).
    private static func tail(_ path: String, before offset: UInt64) -> UInt64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let n = Int(min(64, offset))
        var bytes = [UInt8](repeating: 0, count: n)
        guard pread(fd, &bytes, n, off_t(offset) - off_t(n)) == n else { return 0 }
        return History.fnv(bytes)
    }

    private func line(_ line: UnsafeRawBufferPointer, _ t: Tracked) {
        if t.start == 0, let r = History.topLevel(line, wantCwd: false).timestamp, let s = History.epoch(line, r) { t.start = s }
        // Two writers can splice records into one line; its id and usage don't belong together.
        guard let hit = Self.message(line), TopLevel(line, []).complete else { return }
        if UsageTally.find(line, Self.sessionKey) != nil, !t.own.contains(where: { UsageTally.find(line, $0) != nil }) { return }
        let model = self.model(line)
        if let p = t.pending, p.id == hit.id {
            t.pending = (p.id, model, hit.usage)   // a later block of the same message: its usage is the newer one
            return
        }
        commit(t)
        if let other = owners[hit.id].map(Int.init), !stale.contains(other), let o = slots[other] {
            if other == t.slot { return }          // seen earlier in this file
            guard o.session != t.session, Self.earlier(t, o) else {
                losers[other, default: []].insert(t.slot)
                return
            }
            clear(o)                               // it re-reads without this message
        }
        owners[hit.id] = Int32(t.slot)
        t.pending = (hit.id, model, hit.usage)
    }

    private func commit(_ t: Tracked) {
        guard let p = t.pending else { return }
        t.totals[p.model, default: Usage()] += p.usage
        t.pending = nil
    }

    private func clear(_ t: Tracked) {
        guard !stale.contains(t.slot) else { return }
        stale.insert(t.slot)
        changed = true
        t.totals = [:]
        t.pending = nil
        t.offset = 0
        t.start = 0
        t.read = nil
        if let l = losers.removeValue(forKey: t.slot) {
            for s in l { if let x = slots[s] { clear(x) } }
        }
    }

    /// The session that started first produced the message; the other one copied it.
    private static func earlier(_ a: Tracked, _ b: Tracked) -> Bool {
        if a.start != b.start { return a.start != 0 && (b.start == 0 || a.start < b.start) }
        if a.stat.birth != b.stat.birth { return a.stat.birth < b.stat.birth }
        return a.path < b.path
    }

    /// An assistant line's message id hash and usage. Claude writes one line per
    /// content block, each repeating the message's usage so far.
    static func message(_ line: UnsafeRawBufferPointer) -> (id: UInt64, usage: Usage)? {
        guard UsageTally.find(line, usageKey) != nil,
              UsageTally.find(line, assistantKey) != nil || UsageTally.find(line, assistantKeySpaced) != nil,
              let id = quoted(line, after: idKeys)?.0, let usage = usage(line) else { return nil }
        return (id, usage)
    }

    /// The hash and byte range of the message's model id.
    static func model(_ line: UnsafeRawBufferPointer) -> (UInt64, Range<Int>)? {
        quoted(line, after: modelKeys)
    }

    /// The message's model, interned: the string is only created the first time.
    private func model(_ line: UnsafeRawBufferPointer) -> UInt16 {
        guard let (hash, range) = Self.model(line) else { return internModel("unknown", hash: 0) }
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
    private static let sessionKey = Array("\"sessionId\"".utf8)
    private static let idKeys = [Array("\"id\":\"msg_".utf8), Array("\"id\": \"msg_".utf8)]
    private static let modelKeys = [Array("\"model\":\"".utf8), Array("\"model\": \"".utf8)]

    /// First index of `needle` in `hay[from..<to]`. Compares 16 positions at a time
    /// on two of the needle's bytes, then confirms candidates: libc's memmem is
    /// byte-at-a-time and dominated scans of multi-GB transcript folders. The anchors
    /// skip the first and last byte, which in JSON keys are quotes and match often.
    static func find(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
        let end = to ?? hay.count
        let k = needle.count
        guard let base = hay.baseAddress, k > 0, end - from >= k else { return nil }
        let a1 = k > 2 ? 1 : 0, a2 = k > 3 ? k - 2 : k - 1
        let last = end - k
        return needle.withUnsafeBytes { n -> Int? in
            let nb = n.baseAddress!
            let first = SIMD16<UInt8>(repeating: needle[a1]), second = SIMD16<UInt8>(repeating: needle[a2])
            var i = from
            while i + 15 <= last {
                let x = (base + i + a1).loadUnaligned(as: SIMD16<UInt8>.self)
                let y = (base + i + a2).loadUnaligned(as: SIMD16<UInt8>.self)
                let hits = (x .== first) .& (y .== second)
                if any(hits) {
                    for j in 0..<16 where hits[j] && memcmp(base + i + j, nb, k) == 0 { return i + j }
                }
                i += 16
            }
            while i <= last {
                if memcmp(base + i, nb, k) == 0 { return i }
                i += 1
            }
            return nil
        }
    }

    /// FNV-1a of the quoted value following the first matching key, and its range.
    static func quoted(_ line: UnsafeRawBufferPointer, after keys: [[UInt8]]) -> (UInt64, Range<Int>)? {
        for key in keys {
            guard let at = UsageTally.find(line, key) else { continue }
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

    /// Top-level integers of the last structural `"usage": {...}`. It follows the
    /// message content, where escaped copies (\"usage\") can appear in tool output;
    /// nested objects are skipped by depth, except the 5-minute / 1-hour split of
    /// cache writes, which prices differently.
    private static func usage(_ line: UnsafeRawBufferPointer) -> Usage? {
        var last: Int?
        var from = 0
        while let at = UsageTally.find(line, usageKey, from: from) {
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
                    let hour = UsageTally.find(line, oneHourKey, from: objectStart, to: i).flatMap { integer(line, after: $0 + oneHourKey.count)?.0 } ?? 0
                    return Usage(input: input, cacheWrite5m: max(0, write - hour), cacheWrite1h: hour, cacheRead: read, output: output)
                }
            }
            i += 1
        }
        return nil
    }

    private static let oneHourKey = Array("\"ephemeral_1h_input_tokens\"".utf8)

    /// `: 123` after a key, returning the value and the index after it.
    static func integer(_ line: UnsafeRawBufferPointer, after start: Int) -> (Int, Int)? {
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
    /// A read-only connection kept open between scans: opening the apps' databases
    /// (Cursor's is gigabytes) and reading their schema on every scan cost more than
    /// the queries. Never writes, so it is safe against the apps' live databases.
    final class Connection {
        let path: String
        let ino: UInt64
        private var db: OpaquePointer?

        init?(_ path: String) {
            guard let f = stat(path) else { return nil }
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            sqlite3_busy_timeout(db, 1000)
            self.path = path
            self.db = db
            ino = f.ino
        }

        deinit { sqlite3_close(db) }

        /// Rows of the query as strings / integers.
        func rows(_ sql: String, _ binds: [Int64] = []) -> [[Any?]]? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer {
                sqlite3_finalize(stmt)
                sqlite3_db_release_memory(db)   // keep no page cache between scans
            }
            for (i, v) in binds.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), v) }
            var out: [[Any?]] = []
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
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
                result = sqlite3_step(stmt)
            }
            return result == SQLITE_DONE ? out : nil
        }
    }

    /// Rows of one query, on a connection opened just for it.
    static func rows(_ path: String, _ sql: String, _ binds: [Int64] = []) -> [[Any?]]? {
        Connection(path)?.rows(sql, binds)
    }

    /// The open connection to `path`, reopened if the file was replaced.
    static func connection(_ path: String, _ current: inout Connection?, ino: UInt64?) -> Connection? {
        if let c = current, c.path == path, c.ino == ino { return c }
        current = nil
        current = Connection(path)
        return current
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
        func skipString(_ k: inout Int) { k = Bytes.skipString(b, from: k + 1) }
        while i < b.count {
            let c = b[i]
            if c == 0x22 {
                let start = i
                skipString(&i)
                guard depth == 1 else { continue }
                var j = i
                while j < b.count, Bytes.isSpace(b[j]) { j += 1 }
                guard j < b.count, b[j] == 0x3A else { continue }
                let key = String(decoding: UnsafeRawBufferPointer(rebasing: b[start + 1..<i - 1]), as: UTF8.self)
                j += 1
                while j < b.count, Bytes.isSpace(b[j]) { j += 1 }
                guard j < b.count, keys.contains(key) else { i = j; continue }
                switch b[j] {
                case 0x22:
                    var e = j
                    skipString(&e)
                    out[key] = Bytes.string(b, j..<e)
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
    /// Muster's hook delivers Claude's real permission prompts, so a slow tool call is only slow.
    var promptsByHook = false

    struct FileState {
        var status: Status
        var since: Date
        var title: String
        var cwd: String
        var tools: [String]
        var fault: Fault?
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
        var error: String
    }

    /// A transcript's status, kept current from the lines appended since the last scan.
    private struct Transcript {
        var info: FileInfo?
        var offset: UInt64 = 0
        var turn: Turn?
        var title = ""
        var cwd = ""

        var state: FileState? {
            turn.map { FileState(status: $0.status, since: $0.since, title: title, cwd: cwd, tools: $0.tools, fault: $0.fault) }
        }
    }

    private var transcripts: [String: Transcript] = [:]
    private let subagents = FileCache<(String, Date)?>()
    private let records = FileCache<(String, AppRecord)?>()
    private var agentOwners: [String: String] = [:]       // top-level agent-*.jsonl → its session
    private var agentMisses: [String: UInt64] = [:]
    private let usage = UsageTally()
    private let tree = DirTree()
    private let root: String
    private let appRoot: String
    private(set) var state: SourceState = .notInstalled

    /// CLAUDE_CONFIG_DIR moves ~/.claude, as it does for Claude Code itself.
    init(home: String = home, configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]) {
        root = canonical((configDir ?? home + "/.claude") + "/projects")
        appRoot = canonical(home + "/Library/Application Support/Claude/claude-code-sessions")
    }

    var watchPaths: [String] { [root, appRoot] }

    private static let keys = ["type", "isSidechain", "subtype", "cwd", "timestamp", "isApiErrorMessage"].map { Array($0.utf8) }
    private enum Key: Int { case type, isSidechain, subtype, cwd, timestamp, isApiErrorMessage }
    private static let titleKeys = ["type", "customTitle"].map { Array($0.utf8) }
    private static let customTitle = Array("custom-title".utf8)
    private static let interrupted = Array("[Request interrupted by user".utf8)

    private static func isTurn(_ top: TopLevel) -> Bool {
        let t = top.string(Key.type.rawValue)
        return ((t == "user" || t == "assistant") && top.bool(Key.isSidechain.rawValue) != true)
            || (t == "system" && top.string(Key.subtype.rawValue) == "stop_hook_summary")
    }

    private typealias Turn = (status: Status, since: Date, tools: [String], fault: Fault?)

    /// What the newest turn says, decoding the line only when the bytes can't tell.
    private static func turn(_ line: UnsafeRawBufferPointer, _ top: TopLevel) -> Turn? {
        let since = parseISO(top.string(Key.timestamp.rawValue)) ?? .distantPast
        switch top.string(Key.type.rawValue) {
        case "system":
            return (.done, since, [], nil)
        case "assistant":
            guard let d = decode(line) else { return nil }
            let msg = d["message"] as? [String: Any] ?? [:]
            let content = msg["content"] as? [[String: Any]] ?? []
            let tools = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["name"] as? String }
            let stop = msg["stop_reason"] as? String
            if stop == "tool_use" || !tools.isEmpty {
                return (waitingTools.isDisjoint(with: tools) ? .working : .needsYou, since, tools, nil)
            } else if d["isApiErrorMessage"] as? Bool == true {
                let fault = Fault(code: d["error"] as? String, message: content.compactMap { $0["text"] as? String }.joined(separator: " "))
                return (fault?.status ?? .done, since, tools, fault)
            } else if ["end_turn", "stop_sequence", "max_tokens"].contains(stop ?? "") {
                return (.done, since, tools, nil)
            }
            return (.working, since, tools, nil)
        default:
            // A user turn (often a large tool result) is decoded only if it may be an interruption.
            guard UsageTally.find(line, interrupted) != nil else { return (.working, since, [], nil) }
            guard let d = decode(line) else { return nil }
            let msg = d["message"] as? [String: Any] ?? [:]
            var text = msg["content"] as? String ?? ""
            if let parts = msg["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            }
            return (text.contains("[Request interrupted by user") ? .done : .working, since, [], nil)
        }
    }

    /// Brings a transcript's status up to date from the bytes after `t.offset`, newest
    /// line first: the last turn decides the status. A new file reads back from its end
    /// only as far as its last turn, and the title within that window.
    private static func update(_ t: inout Transcript, _ f: FileInfo) {
        let fd = open(f.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var haveTurn = false, haveTitle = false, haveCwd = false
        var next = t
        // A turn too long to load is one giant tool result in all but name: its first
        // 64 KB give its type, and its time if Claude wrote it before the content.
        let oversized = { (head: UnsafeRawBufferPointer) -> Bool in
            guard !haveTurn else { return !haveTitle }
            let top = TopLevel(head, keys)
            if !haveCwd, let cwd = top.string(Key.cwd.rawValue) {
                next.cwd = cwd
                haveCwd = true
            }
            if isTurn(top) {
                let since = parseISO(top.string(Key.timestamp.rawValue)) ?? f.mtime
                next.turn = (top.string(Key.type.rawValue) == "system" ? .done : .working, since, [], nil)
                haveTurn = true
            }
            return true
        }
        let end = LineReader.reverse(fd, from: t.offset, to: f.size, grow: { !haveTurn }, oversized: oversized) { line in
            if !haveTitle, UsageTally.find(line, customTitle) != nil {
                let top = TopLevel(line, titleKeys)
                if top.complete, top.string(0) == "custom-title" {
                    next.title = top.string(1) ?? ""
                    haveTitle = true
                }
            }
            guard !haveTurn else { return !haveTitle }
            let top = TopLevel(line, keys)
            guard top.complete else { return true }
            if !haveCwd, let cwd = top.string(Key.cwd.rawValue) {
                next.cwd = cwd
                haveCwd = true
            }
            if isTurn(top), let turn = turn(line, top) {
                next.turn = turn
                haveTurn = true
            }
            return true
        }
        next.offset = end
        t = next
    }

    private func transcript(_ f: FileInfo) -> FileState? {
        var t = transcripts[f.path] ?? Transcript()
        if f.same(t.info) { return t.state }
        if let old = t.info, f.ino != old.ino || f.size < t.offset { t = Transcript() }   // replaced or truncated
        Self.update(&t, f)
        t.info = f
        transcripts[f.path] = t
        return t.state
    }

    private static let subagentKeys = ["sessionId", "timestamp"].map { Array($0.utf8) }

    /// The session a subagent works for and when it last wrote: its newest line.
    private static func parseSubagent(_ path: String) -> (String, Date)? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0, let size = stat(path)?.size else { if fd >= 0 { close(fd) }; return nil }
        defer { close(fd) }
        var hit: (String, Date)?
        _ = LineReader.reverse(fd, from: 0, to: size) { line in
            let top = TopLevel(line, subagentKeys)
            guard top.complete, let sid = top.string(0) else { return true }
            hit = (sid, parseISO(top.string(1)) ?? .distantPast)
            return false
        }
        return hit
    }

    private static let sessionIdKeys = [Array("\"sessionId\":\"".utf8), Array("\"sessionId\": \"".utf8)]

    /// The session a top-level agent-*.jsonl (older Claude Code's subagent transcript)
    /// belongs to, from its first line. Read once per file.
    private func owner(_ f: FileInfo) -> String? {
        if let o = agentOwners[f.path] { return o }
        if agentMisses[f.path] == f.size { return nil }
        let o: String? = LineReader.first(f.path) { line in
            var last: Range<Int>?
            for key in Self.sessionIdKeys {
                var from = 0
                while let at = UsageTally.find(line, key, from: from) {
                    let start = at + key.count
                    var e = start
                    while e < line.count, line[e] != 0x22 { e += 1 }
                    if e < line.count { last = start..<e }
                    from = start
                }
            }
            return last.map { String(decoding: UnsafeRawBufferPointer(rebasing: line[$0]), as: UTF8.self) }
        }
        if let o { agentOwners[f.path] = o; agentMisses[f.path] = nil } else { agentMisses[f.path] = f.size }
        return o
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
            errorAt: d["error"] != nil ? ms("errorAt") : nil,
            error: d["error"] as? String ?? ""))
    }

    /// Claude.app's own session list, keyed by transcript id: its deep links take the
    /// app id (local_…), its titles are the sidebar's, and it knows when a turn is open.
    private func appIndex(now: Date, changes: Changes) -> (index: [String: AppRecord], exists: Bool) {
        var index: [String: AppRecord] = [:]
        guard let top = tree.node(appRoot, changes, root: true, want: { _ in false }) else { return (index, false) }
        for a in top.dirs {
            let ad = appRoot + "/" + a
            guard let an = tree.node(ad, changes, want: { _ in false }) else { continue }
            for b in an.dirs {
                guard let bn = tree.node(ad + "/" + b, changes, want: { $0.hasPrefix("local_") && $0.hasSuffix(".json") }) else { continue }
                for (_, f) in bn.files where now.timeIntervalSince(f.mtime) <= 24 * 3600 {
                    guard let r = records.value(f.path, size: f.size, mtime: f.mtime, parse: Self.parseRecord) else { continue }
                    index[r.0] = r.1
                }
            }
        }
        return (index, true)
    }

    /// Agent transcripts below a session's subagents folder (workflows nest them deeper).
    private func nested(_ dir: String, _ changes: Changes, depth: Int, into out: inout [FileInfo]) {
        guard depth > 0, let n = tree.node(dir, changes, want: { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }) else { return }
        out += n.files.map(\.info)
        for d in n.dirs { nested(dir + "/" + d, changes, depth: depth - 1, into: &out) }
    }

    func scan(now: Date) -> [Session] { scan(now: now, changes: .all) }

    func scan(now: Date, changes: Changes) -> [Session] {
        tree.begin(changes)
        defer {
            tree.end()
            if changes.full { subagents.sweep(); records.sweep() }
        }
        let (app, appExists) = appIndex(now: now, changes: changes)
        var out: [String: Session] = [:]
        var pending: [String: [String]] = [:]
        var transcriptsOf: [String: [FileInfo]] = [:]
        var subagentsOf: [String: [FileInfo]] = [:]
        var agentFiles: [FileInfo] = []
        var subLast: [String: Date] = [:]
        var seen: Set<String> = []

        let top = tree.node(root, changes, root: true, want: { _ in false })
        for project in top?.dirs ?? [] {
            let dir = root + "/" + project
            guard let p = tree.node(dir, changes, want: { $0.hasSuffix(".jsonl") }) else { continue }
            for (name, f) in p.files {
                if name.hasPrefix("agent-") { agentFiles.append(f); continue }   // a subagent, never a session
                guard now.timeIntervalSince(f.mtime) <= recentWindow, let s = transcript(f) else { continue }
                seen.insert(f.path)
                let sid = String(name.dropLast(6))
                let a = app[sid]
                if a?.archived == true { continue }
                transcriptsOf[sid, default: []].append(f)
                pending[sid] = s.tools
                out[sid] = Session(agent: .claude, sid: sid, status: s.status, since: s.since,
                                   title: (a?.title).flatMap { $0.isEmpty ? nil : $0 } ?? s.title,
                                   project: s.cwd, appID: a?.appID ?? "", fault: s.fault)
            }
            for d in p.dirs {
                let sub = dir + "/" + d + "/subagents"
                guard let s = tree.node(sub, changes, want: { $0.hasSuffix(".jsonl") }) else { continue }
                for (_, f) in s.files where now.timeIntervalSince(f.mtime) <= 3600 {
                    guard let hit = subagents.value(f.path, size: f.size, mtime: f.mtime, parse: Self.parseSubagent) else { continue }
                    subLast[hit.0] = max(subLast[hit.0] ?? .distantPast, hit.1)
                }
                // A session's folder sits beside its transcript, which this project listed first.
                guard transcriptsOf[d] != nil else { continue }
                var files = s.files.map(\.info)
                for w in s.dirs { nested(sub + "/" + w, changes, depth: 3, into: &files) }
                subagentsOf[d, default: []] += files
            }
        }
        if seen.count < transcripts.count { transcripts = transcripts.filter { seen.contains($0.key) } }
        if changes.full {
            let present = Set(agentFiles.map(\.path))
            agentOwners = agentOwners.filter { present.contains($0.key) }
            agentMisses = agentMisses.filter { present.contains($0.key) }
        }

        usage.begin()
        for (sid, files) in transcriptsOf {
            for f in files { usage.add(f, session: sid) }
            for f in subagentsOf[sid] ?? [] { usage.add(f, session: sid) }
        }
        for f in agentFiles {
            if let owner = owner(f), transcriptsOf[owner] != nil { usage.add(f, session: owner) }
        }
        usage.end()

        for (sid, var o) in out {
            if transcriptsOf[sid] != nil { o.account(usage.usage(of: sid)) }
            if let sub = subLast[sid], o.status == .done, sub > o.since {
                o.status = now.timeIntervalSince(sub) <= Self.subagentLive ? .working : .done
                o.since = sub
            }
            out[sid] = o
        }

        for (sid, a) in app where !a.archived {
            if a.turnOpen, now.timeIntervalSince(a.activity) <= Self.appTurnLive {
                if var o = out[sid] {
                    if o.status != .needsYou, a.activity > o.since { o.status = .working; o.since = a.activity; o.fault = nil }
                    out[sid] = o
                } else {
                    out[sid] = Session(agent: .claude, sid: sid, status: .working, since: a.activity,
                                       title: a.title, project: a.cwd, appID: a.appID)
                }
            }
            guard var o = out[sid] else { continue }
            if let e = a.errorAt, e >= o.since, now.timeIntervalSince(e) <= recentWindow, let f = Fault(message: a.error) {
                o.fail(f, at: e)
            }
            // Permission prompts are never written to disk. In a mode that can prompt,
            // a tool call left unanswered this long is usually one. Only a guess: a long build
            // looks the same, so with the hook delivering the real prompts it isn't made.
            if !promptsByHook, o.status == .working, Self.promptingModes.contains(a.permissionMode),
               let tools = pending[sid], !tools.isEmpty, !Set(tools).isSubset(of: Self.noPromptTools),
               now.timeIntervalSince(max(o.since, a.activity)) >= Self.permissionWait {
                o.status = .needsYou
            }
            out[sid] = o
        }
        state = top != nil || appExists ? .ok(out.count) : .notInstalled
        return Array(out.values)
    }
}

// MARK: - Codex (desktop app and CLI)

final class CodexReader {
    private static let eventKeys = ["token_count", "task_started", "task_complete", "turn_aborted", "turn_context",
                                    "request_user_input", "function_call_output", "send_user_message_question_reply",
                                    "\"role\":\"user\"", "\"role\": \"user\""].map { Array($0.utf8) }

    /// A rollout's state, kept current from the lines appended since the last scan.
    private struct Rollout {
        var info: FileInfo?
        var offset: UInt64 = 0
        var status: (Status, Date)?
        var activity = Date.distantPast
        var model: String?
        var totals: [String: Any]?   // the newest running total_token_usage
        /// Async questions can outlive the turn that asked them. Keep each unanswered call
        /// so answering a newer question cannot hide an older one.
        var questions: [String: (texts: [Int: String], at: Date)] = [:]

        /// How long an unanswered question keeps asking: Muster's three-hour window. Past that,
        /// or once you've written to the thread since, it's no longer waiting on you.
        static let questionLife: TimeInterval = recentWindow

        func result(now: Date) -> (Status, Date, [String: Usage], String?)? {
            guard let status else { return nil }
            // token_count carries running totals for the whole thread; the model comes
            // from the latest turn_context. Input includes the cached part.
            var usage: [String: Usage] = [:]
            if let t = totals {
                let n = { (k: String) in (t[k] as? NSNumber)?.intValue ?? 0 }
                let cached = n("cached_input_tokens"), write = n("cache_write_input_tokens")
                usage[model ?? "unknown"] = Usage(input: max(0, n("input_tokens") - cached - write), cacheWrite5m: write, cacheWrite1h: 0,
                                                  cacheRead: cached, output: n("output_tokens"))
            }
            if let batch = questions.values.filter({ now.timeIntervalSince($0.at) <= Self.questionLife }).max(by: { $0.at < $1.at }),
               let index = batch.texts.keys.min(), let first = batch.texts[index] {
                let text = batch.texts.count > 1 ? "\(first) (and \(batch.texts.count - 1) more)" : first
                return (.needsYou, max(batch.at, status.1), usage, text)
            }
            return (status.0, status.1, usage, nil)
        }
    }

    private struct Row { let id, path, title, cwd: String; let updated: Int64 }

    private var rollouts: [String: Rollout] = [:]
    private var rows: [Row]?
    private var rowsReadable = true
    private var dbStamp: [FileInfo?] = []
    private var connection: SQLiteRO.Connection?
    private let tree = DirTree()
    private let root: String
    private(set) var state: SourceState = .notInstalled

    /// CODEX_HOME moves ~/.codex, as it does for Codex itself.
    init(home: String = home, codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"]) {
        root = canonical(codexHome ?? home + "/.codex")
    }

    var watchPaths: [String] { [root] }

    /// Newest first, the latest status event, token total and model in the new bytes.
    private static func update(_ r: inout Rollout, _ f: FileInfo) {
        let fd = open(f.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var next = r
        var haveStatus = false, haveTotals = false, haveModel = false
        var replied: [String: Set<Int>] = [:]
        var completed: Set<String> = []
        var wrote = false             // you wrote to the thread in these bytes: what came before is behind you
        var asked: Set<String> = []   // questions read in these bytes after your newest message
        next.offset = LineReader.reverse(fd, from: r.offset, to: f.size) { line in
            guard Bytes.has(line, eventKeys), let d = decode(line) else { return true }
            let p = d["payload"] as? [String: Any]
            if p?["type"] as? String == "message", let text = Self.text(p), text.contains("send_user_message_question_reply") {
                for reply in Self.questionReplies(text) {
                    if let index = reply.index { replied[reply.call, default: []].insert(index) }
                    else { completed.insert(reply.call) }
                }
            } else if !wrote, p?["type"] as? String == "message", p?["role"] as? String == "user",
                      let text = Self.text(p), Self.written(text) {
                wrote = true
            } else if p?["type"] as? String == "function_call_output", let id = p?["call_id"] as? String {
                let output = (p?["output"] as? String).flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                if output?["accepted"] as? Bool != true { completed.insert(id) }
            } else if p?["type"] as? String == "function_call",
                      let name = (p?["name"] as? String)?.split(separator: ".").last,
                      name == "request_user_input_async" || name == "request_user_input",
                      let id = p?["call_id"] as? String, !completed.contains(id), !wrote {
                next.questions[id] = (Self.questionTexts(p?["arguments"] as? String), parseISO(d["timestamp"]) ?? .distantPast)
                asked.insert(id)
            }
            if !haveModel, d["type"] as? String == "turn_context", let m = p?["model"] as? String {
                next.model = m
                haveModel = true
            }
            switch p?["type"] as? String {
            case "token_count":
                if let at = parseISO(d["timestamp"]) { next.activity = max(next.activity, at) }
                if !haveTotals, let info = p?["info"] as? [String: Any] {
                    next.totals = info["total_token_usage"] as? [String: Any] ?? [:]
                    haveTotals = true
                }
            case "task_started":
                if !haveStatus { next.status = (.working, parseISO(d["timestamp"]) ?? .distantPast); haveStatus = true }
            case "task_complete", "turn_aborted":
                if !haveStatus { next.status = (.done, parseISO(d["timestamp"]) ?? .distantPast); haveStatus = true }
            default:
                break
            }
            return true
        }
        // A reply appended later answers a question read on an earlier scan.
        for id in completed { next.questions[id] = nil }
        if wrote { next.questions = next.questions.filter { asked.contains($0.key) } }
        for (id, indices) in replied {
            guard var batch = next.questions[id] else { continue }
            for index in indices { batch.texts[index] = nil }
            next.questions[id] = batch.texts.isEmpty ? nil : batch
        }
        r = next
    }

    /// A message you wrote, not one Codex adds to the conversation itself (AGENTS.md,
    /// environment context and the like arrive as user messages too).
    static func written(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("# AGENTS.md")
    }

    private static func text(_ p: [String: Any]?) -> String? {
        (p?["content"] as? String) ?? (p?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func callIDs(_ text: String) -> Set<String> {
        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
        return Set(words.filter { $0.hasPrefix("call_") }.map(String.init))
    }

    private static func questionReplies(_ text: String) -> [(call: String, index: Int?)] {
        let body = text.components(separatedBy: "<send_user_message_question_reply>").last?
            .components(separatedBy: "</send_user_message_question_reply>").first ?? text
        guard let records = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]] else {
            return callIDs(text).map { ($0, nil) } // older replies identified only the call
        }
        return records.compactMap { record in
            let raw = record["questionItemId"] as? String ?? ""
            guard let parts = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any],
                  let call = parts.compactMap({ $0 as? String }).first(where: { $0.hasPrefix("call_") }) else { return nil }
            return (call, parts.count > 2 ? parts.last as? Int : nil)
        }
    }

    private static func questionTexts(_ arguments: String?) -> [Int: String] {
        let d = arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        let qs = d?["questions"] as? [[String: Any]] ?? []
        guard !qs.isEmpty else { return [0: "Codex has a question"] }
        return Dictionary(uniqueKeysWithValues: qs.enumerated().map { index, q in
            (index, (q["title"] ?? q["question"]) as? String ?? "Codex has a question")
        })
    }

    /// A rollout's state. Its path is whatever Codex stored, which needn't match how
    /// FSEvents names it, and there are only a few, so each is stat'd every scan.
    private func rollout(_ path: String, now: Date) -> (Status, Date, [String: Usage], String?)? {
        var r = rollouts[path] ?? Rollout()
        guard let f = stat(path) else { rollouts[path] = nil; return nil }
        if !f.same(r.info) {
            if let old = r.info, f.ino != old.ino || f.size < r.offset { r = Rollout() }
            Self.update(&r, f)
            r.info = f
        }
        rollouts[path] = r
        return r.result(now: now)
    }

    func scan(now: Date) -> [Session] { scan(now: now, changes: .all) }

    func scan(now: Date, changes: Changes) -> [Session] {
        tree.begin(changes)
        defer { tree.end() }
        guard let node = tree.node(root, changes, root: true, want: { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }) else {
            state = .notInstalled
            rows = nil
            rollouts = [:]
            return []
        }
        guard let db = node.files.max(by: { version($0.name) < version($1.name) })?.info else {
            state = .unreadable("Codex is installed but has no thread database yet")
            return []
        }
        let cutoff = Int64((now.timeIntervalSince1970 - recentWindow) * 1000)
        if rows == nil || !rowsReadable || changes.touches(root) {
            let stamp = [db, stat(db.path + "-wal")]
            if rows == nil || !rowsReadable || stamp != dbStamp {
                // An open connection would keep reading a file that just became unreadable.
                if access(db.path, R_OK) != 0 { connection = nil }
                let refreshed: [Row]? = access(db.path, R_OK) != 0 ? nil : SQLiteRO.connection(db.path, &connection, ino: db.ino)?.rows(
                    "SELECT id, rollout_path, COALESCE(NULLIF(name,''), NULLIF(title,''), first_user_message, ''), cwd, updated_at_ms " +
                    "FROM threads WHERE archived = 0 AND updated_at_ms > ?", [cutoff])?.compactMap { r in
                        guard let id = r[0] as? String, let path = r[1] as? String else { return nil }
                        return Row(id: id, path: path, title: r[2] as? String ?? "", cwd: r[3] as? String ?? "", updated: r[4] as? Int64 ?? 0)
                    }
                rowsReadable = refreshed != nil
                if let refreshed { rows = refreshed; dbStamp = stamp }
            }
        }
        guard let rows else {
            state = .unreadable("Can't read Codex's thread list. Its format may have changed.")
            return []
        }
        // Rows only leave the window between writes, so the cutoff is applied again here.
        let live = rows.filter { $0.updated > cutoff }
        let found: [Session] = live.compactMap { r in
            guard let res = rollout(r.path, now: now) else { return nil }
            var s = Session(agent: .codex, sid: r.id, status: res.0, since: res.1,
                            title: String(r.title.prefix(80)), project: r.cwd, appID: "")
            s.asking = res.3
            s.lastActivity = rollouts[r.path]?.activity
            s.account(res.2)
            return s
        }
        if rollouts.count > live.count {
            let keep = Set(live.map(\.path))
            rollouts = rollouts.filter { keep.contains($0.key) }
        }
        state = rowsReadable ? .ok(found.count) : .unreadable("Can't read Codex's thread list. Will try again.")
        return found
    }

    private func version(_ name: String) -> Int {
        Int((name as NSString).deletingPathExtension.split(separator: "_").last ?? "") ?? -1
    }
}

// MARK: - Cursor agent chats

final class CursorReader {
    static let activeWindow: TimeInterval = 600   // a checkpoint this recent with no turn end counts as running
    static let endSlack: TimeInterval = 30         // turn_ended can land just before the final checkpoint

    private struct Transcript { var info: FileInfo; var status: Status; var title: String; var fault: Fault? }

    private var transcripts: [String: Transcript] = [:]
    private var workspaces: [String: String] = [:]
    private let tree = DirTree()
    private let root: String
    private let db: String
    private var connection: SQLiteRO.Connection?
    private(set) var state: SourceState = .notInstalled
    private var headersReadable = true

    init(home: String = home) {
        root = canonical(home + "/.cursor/projects")
        db = canonical(home + "/Library/Application Support/Cursor/User/globalStorage") + "/state.vscdb"
    }

    var watchPaths: [String] { [root, parent(db)] }

    private static let statusKeys = ["type", "status"].map { Array($0.utf8) }

    /// The newest line says whether the turn ended; the first line's query titles it.
    private func transcript(_ f: FileInfo) -> Transcript {
        let old = transcripts[f.path]
        if let old, f.same(old.info) { return old }
        var status = Status.working
        var fault: Fault?
        let fd = open(f.path, O_RDONLY)
        if fd >= 0 {
            _ = LineReader.reverse(fd, from: 0, to: f.size) { line in
                guard let last = decode(line) else { return true }
                if last["type"] as? String == "turn_ended" {
                    // Cursor ends a turn you cancelled with an error too.
                    if last["status"] as? String == "error" { fault = Fault(message: last["error"] as? String ?? "") }
                    status = fault?.status ?? .done
                }
                return false
            }
            close(fd)
        }
        var title = old.flatMap { $0.info.ino == f.ino && f.size >= $0.info.size ? $0.title : nil } ?? ""
        if title.isEmpty { title = Self.title(f.path) }
        let t = Transcript(info: f, status: status, title: title, fault: fault)
        transcripts[f.path] = t
        return t
    }

    private static func title(_ path: String) -> String {
        guard let first = LineReader.first(path, decode), let msg = first["message"] as? [String: Any],
              let parts = msg["content"] as? [[String: Any]], var text = parts.first?["text"] as? String else { return "" }
        if let r = text.range(of: "<user_query>") {
            text = String(text[r.upperBound...])
            if let e = text.range(of: "</user_query>") { text = String(text[..<e.lowerBound]) }
        }
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
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

    private var headerCache: (key: [FileInfo?], value: [String: [String: Any]])?

    /// The Agents window's chat list, re-read only when the database or its WAL changes.
    private func headers(now: Date, changes: Changes) -> [String: [String: Any]] {
        if headersReadable, let c = headerCache, !changes.touches(parent(db)) { return c.value }
        let key = [stat(db), stat(db + "-wal")]
        if headersReadable, let c = headerCache, c.key == key { return c.value }
        var out: [String: [String: Any]] = [:]
        let cutoff = Int64((now.timeIntervalSince1970 - recentWindow) * 1000)
        // An open connection would keep reading a file that just became unreadable.
        if key[0] == nil || access(db, R_OK) != 0 { connection = nil }
        let rows = key[0].flatMap { access(db, R_OK) == 0 ? SQLiteRO.connection(db, &connection, ino: $0.ino) : nil }?.rows(
            "SELECT composerId, value FROM composerHeaders WHERE isSubagent = 0 AND isArchived = 0 " +
            "AND MAX(lastUpdatedAt, COALESCE(checkpointAt, 0)) > ?", [cutoff])
        headersReadable = rows != nil || key[0] == nil
        // A lock can clear without changing either file. Keep the last good list
        // and retry next scan instead of caching the failure as an empty database.
        guard headersReadable else { return headerCache?.value ?? [:] }
        for r in rows ?? [] {
            if let id = r[0] as? String, let h = jsonObject(r[1]) { out[id] = h }
        }
        headerCache = (key, out)
        return out
    }

    func scan(now: Date) -> [Session] { scan(now: now, changes: .all) }

    func scan(now: Date, changes: Changes) -> [Session] {
        tree.begin(changes)
        defer { tree.end() }
        var fromFiles: [String: (Status, Date, String, String, Fault?)] = [:]
        let top = tree.node(root, changes, root: true, want: { _ in false })
        var seen: Set<String> = []
        for project in top?.dirs ?? [] {
            let transcriptsDir = root + "/" + project + "/agent-transcripts"
            guard let t = tree.node(transcriptsDir, changes, want: { _ in false }) else { continue }
            for sid in t.dirs {
                let file = sid + ".jsonl"
                guard let n = tree.node(transcriptsDir + "/" + sid, changes, want: { $0 == file }),
                      let f = n.files.first?.info, now.timeIntervalSince(f.mtime) <= recentWindow else { continue }
                seen.insert(f.path)
                let r = transcript(f)
                fromFiles[sid] = (r.status, f.mtime, r.title, project, r.fault)
            }
        }
        if seen.count < transcripts.count { transcripts = transcripts.filter { seen.contains($0.key) } }
        let headers = self.headers(now: now, changes: changes)

        var out: [Session] = []
        for sid in Set(fromFiles.keys).union(headers.keys) {
            let h = headers[sid] ?? [:]
            var (status, since, title, folder, fault) = fromFiles[sid] ?? (.working, .distantPast, "", "", nil)
            let ws = (((h["workspaceIdentifier"] as? [String: Any])?["uri"] as? [String: Any])?["fsPath"] as? String)
                ?? (folder.isEmpty ? "" : workspace(folder))
            let ms = max((h["conversationCheckpointLastUpdatedAt"] as? NSNumber)?.doubleValue ?? 0,
                         (h["lastUpdatedAt"] as? NSNumber)?.doubleValue ?? 0)
            let activity = Date(timeIntervalSince1970: ms / 1000)
            if h["hasBlockingPendingActions"] as? Bool == true {
                status = .needsYou
                since = max(activity, since)
            } else if fromFiles[sid] != nil, [.done, .error, .blocked].contains(status), since >= activity.addingTimeInterval(-Self.endSlack) {
            } else if activity > since, now.timeIntervalSince(activity) <= Self.activeWindow {
                status = .working
                since = activity
            } else if fromFiles[sid] == nil {
                continue
            }
            out.append(Session(agent: .cursor, sid: sid, status: status, since: since,
                               title: (h["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title,
                               project: ws, appID: "", fault: status == .error || status == .blocked ? fault : nil))
        }
        if !headersReadable {
            state = .unreadable("Can't read Cursor's chat list. Its format may have changed.")
        } else if top == nil && headerCache.map({ $0.key[0] == nil }) ?? true {
            state = .notInstalled
        } else {
            state = .ok(out.count)
        }
        return out
    }
}
