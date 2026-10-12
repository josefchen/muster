import Foundation

// The soak: ten agents writing the way real ones do (bursts of tool calls, usage on
// every assistant line, results from a few hundred bytes to half a megabyte) plus
// one 500 MB transcript that keeps growing, while the app's CPU time and physical
// footprint are sampled from the kernel.

enum Soak {
    /// % of one core, averaged. CI's short run on a shared VM sets a looser
    /// MUSTER_SOAK_CPU_LIMIT, so it catches regressions without flaking.
    static let cpuLimit = ProcessInfo.processInfo.environment["MUSTER_SOAK_CPU_LIMIT"].flatMap(Double.init) ?? 1.5
    static let footprintLimit = 35.0  // MB, at any sample
    static let sampleEvery = 3.0

    /// Plain words: tool output, safe inside a JSON string without escaping.
    static let filler: [UInt8] = {
        let words = ["build", "test", "passed", "warning", "src", "main", "func", "return", "let", "cache", "error", "ok",
                     "request", "module", "index", "value", "layout", "render", "token", "stream", "parse", "query"]
        var out: [UInt8] = []
        out.reserveCapacity(700_000)
        while out.count < 700_000 {
            out.append(contentsOf: Array(words.randomElement()!.utf8))
            out.append(out.count % 97 < 8 ? 0x2E : 0x20)
        }
        return out
    }()

    static func size() -> Int {
        let r = Double.random(in: 0..<1)
        if r < 0.6 { return Int.random(in: 200...4_000) }
        if r < 0.9 { return Int.random(in: 4_000...30_000) }
        if r < 0.99 { return Int.random(in: 30_000...150_000) }
        return Int.random(in: 150_000...600_000)
    }

    static func text(_ n: Int) -> String {
        let start = Int.random(in: 0..<(filler.count - n))
        return String(decoding: filler[start..<start + n], as: UTF8.self)
    }
}

class SoakAgent {
    var due = Date()
    private(set) var lines = 0
    private(set) var bytes = 0

    func begin() {}
    func step(_ now: Date) {}

    /// Writes lines to the agent's file, starting it afresh or appending.
    func emit(fresh: Bool = false, _ chunks: Data...) {
        let d = chunks.reduce(Data(), +)
        lines += chunks.count
        bytes += d.count
        put(d, fresh: fresh)
    }

    func put(_ d: Data, fresh: Bool) {}

    func after(_ range: ClosedRange<Double>) { due = Date().addingTimeInterval(Double.random(in: range)) }
}

final class ClaudeAgent: SoakAgent {
    let c: ClaudeFixture
    private var calls = 0
    private var awaitingResult = false

    init(_ fx: Fixture, _ i: Int) { c = ClaudeFixture(fx, project: "agent-\(i)") }

    override func put(_ d: Data, fresh: Bool) { fresh ? c.write(d) : c.append(d) }

    override func begin() {
        emit(fresh: true, c.title("Agent \(c.sid.prefix(4))"), c.user("Start on the backlog"))
        calls = Int.random(in: 3...12)
        after(0.2...2)
    }

    override func step(_ now: Date) {
        if awaitingResult {
            emit(c.toolResult(Soak.text(Soak.size())))
            awaitingResult = false
            calls -= 1
            if calls <= 0 {
                emit(c.reply("Finished this step; " + Soak.text(300)))
                after(4...20)
            } else {
                after(0.05...1.2)
            }
        } else if calls <= 0 {
            emit(c.user("Next: " + Soak.text(120)))
            calls = Int.random(in: 3...12)
            after(0.3...2)
        } else {
            let id = "msg_" + hex(24)
            let tool = ["Bash", "Read", "Edit", "Grep", "Write"].randomElement()!
            emit(c.text(Soak.text(Int.random(in: 40...600)), id: id), c.toolUse(tool, input: ["command": Soak.text(60)], id: id))
            awaitingResult = true
            after(0.2...3)
        }
    }
}

final class CodexAgent: SoakAgent {
    let x: CodexFixture
    private var calls = 0
    private var inTask = false
    private var total = 12_000

    init(_ fx: Fixture, _ i: Int) { x = CodexFixture(fx, project: "codex-\(i)") }

    override func put(_ d: Data, fresh: Bool) { fresh ? x.write(d) : x.append(d) }

    override func begin() {
        emit(fresh: true, x.turnContext(), x.started())
        x.register(title: "Codex agent \(x.id.prefix(4))")
        inTask = true
        calls = Int.random(in: 3...10)
        after(0.2...2)
    }

    override func step(_ now: Date) {
        if !inTask {
            emit(x.turnContext(), x.started())
            x.touchRow()
            inTask = true
            calls = Int.random(in: 3...10)
            after(0.3...2)
        } else if calls <= 0 {
            emit(x.completed())
            x.touchRow()
            inTask = false
            after(4...20)
        } else {
            total += Int.random(in: 2_000...20_000)
            emit(x.call(Soak.text(40)), x.output(Soak.text(Soak.size())), x.tokens(total))
            calls -= 1
            after(0.2...2.5)
        }
    }
}

final class CursorAgent: SoakAgent {
    let u: CursorFixture
    private var calls = 0
    private var inTurn = false

    init(_ fx: Fixture, _ i: Int) { u = CursorFixture(fx, project: "cursor-\(i)") }

    override func put(_ d: Data, fresh: Bool) { fresh ? u.write(d) : u.append(d) }

    override func begin() {
        emit(fresh: true, u.query("Refactor the settings screen"))
        u.header(name: "Cursor agent \(u.sid.prefix(4))", blocking: false)
        inTurn = true
        calls = Int.random(in: 3...10)
        after(0.2...2)
    }

    override func step(_ now: Date) {
        if !inTurn {
            emit(u.query(Soak.text(120)))
            u.header(name: "Cursor agent \(u.sid.prefix(4))", blocking: false)
            inTurn = true
            calls = Int.random(in: 3...10)
            after(0.3...2)
        } else if calls <= 0 {
            emit(u.turnEnded())
            u.header(name: "Cursor agent \(u.sid.prefix(4))", blocking: false)
            inTurn = false
            after(4...20)
        } else {
            emit(u.assistant(Soak.text(Soak.size())))
            calls -= 1
            after(0.2...2.5)
        }
    }
}

/// A transcript of `target` bytes: a long session's worth of tool calls, each with
/// its own message id and usage, and results of realistic sizes.
func writeMonolith(_ c: ClaudeFixture, bytes target: Int) -> Int {
    let path = c.fx.path(c.rel)
    c.fx.write(c.rel, c.title("Monolith"))
    guard let fh = FileHandle(forWritingAtPath: path) else { fatal("can't write the big transcript") }
    defer { try? fh.close() }
    _ = try? fh.seekToEnd()
    var written = c.fx.size(c.rel)
    var batch = Data()
    batch.reserveCapacity(9 << 20)
    var t = Date().addingTimeInterval(-7000)
    let head = Data("{\"type\":\"user\",\"isSidechain\":false,\"userType\":\"external\",\"sessionId\":\"\(c.sid)\",\"cwd\":\"\(c.cwd)\",\"timestamp\":\"".utf8)
    while written + batch.count < target {
        batch += c.toolUse(["Bash", "Read", "Edit"].randomElement()!, input: ["command": "make test"], at: t)
        batch += head + Data(iso(t).utf8) + Data("\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_\(hex(8))\",\"content\":\"".utf8)
        let n = Soak.size(), start = Int.random(in: 0..<(Soak.filler.count - n))
        batch += Soak.filler[start..<start + n]
        batch += Data("\"}]}}\n".utf8)
        t = t.addingTimeInterval(0.25)
        if batch.count >= 8 << 20 {
            try? fh.write(contentsOf: batch)
            written += batch.count
            batch.removeAll(keepingCapacity: true)
        }
    }
    batch += c.reply("Wrapped up the monolith.")
    try? fh.write(contentsOf: batch)
    return written + batch.count
}

private struct Sample {
    let t: Double          // seconds since the first sample
    let cpu: Double        // CPU seconds used so far
    let footprint: Double  // MB
}

/// CPU seconds as ps reports them, to cross-check the kernel's numbers.
private func psCPU(_ pid: pid_t) -> Double? {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "time=", "-p", String(pid)]
    p.standardOutput = out
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.split(separator: ":").reduce(0.0) { acc, part in Double(part).map { acc * 60 + $0 } ?? acc }
}

private func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? 0 : s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Least squares: MB per minute and how well a line fits.
private func trend(_ samples: [Sample]) -> (slope: Double, r2: Double) {
    let xs = samples.map { $0.t / 60 }, ys = samples.map(\.footprint)
    let n = Double(xs.count)
    guard n >= 3 else { return (0, 0) }
    let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
    let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
    let syy = ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }
    guard sxx > 0, syy > 0 else { return (0, 0) }
    return (sxy / sxx, sxy * sxy / (sxx * syy))
}

func runSoak(bundle: String, minutes: Double) -> Never {
    let started = Date()
    print("Muster e2e: soak, \(minutes.formatted()) min")
    wipeDefaults()
    let fx = Fixture()
    fx.mkdir(".claude/projects")
    fx.mkdir("Library/Application Support/Claude/claude-code-sessions")
    fx.mkdir(".cursor/projects")
    CodexFixture.createDB(fx)
    CursorFixture.createDB(fx)

    var fs = statfs()
    if statfs(fx.root, &fs) == 0, UInt64(fs.f_bavail) * UInt64(fs.f_bsize) < 2 << 30 {
        fx.cleanup()
        fatal("the soak needs 2 GB free in the temp folder")
    }
    let big = ClaudeFixture(fx, project: "monolith")
    let t0 = Date()
    let size = writeMonolith(big, bytes: 500 << 20)
    note("wrote a \(mb(UInt64(size))) transcript in \(secs(Date().timeIntervalSince(t0)))")
    let agents: [SoakAgent] = (0..<6).map { ClaudeAgent(fx, $0) } + (0..<2).map { CodexAgent(fx, $0) } + (0..<2).map { CursorAgent(fx, $0) }
    agents.forEach { $0.begin() }

    let app = App(bundle: bundle, fixture: fx)
    guard app.launch(timeout: 60) else {
        appMessages(fx).forEach { note($0) }
        fx.cleanup()
        fatal("the app didn't start (\(app.exitDescription))")
    }
    section("Setup")
    expect(app, "all 11 sessions are listed, the 500 MB one included", within: 60) { $0.sessions.count == 11 }
    if let u = app.usage() { note("after the first scan: \(mb(u.footprint)), peak \(mb(u.peak)), \(secs(u.cpu)) CPU") }

    func drive(until end: Date, sample: ((Date) -> Void)? = nil) {
        var nextBig = Date().addingTimeInterval(20)
        while Date() < end, app.alive {
            let now = Date()
            for a in agents where a.due <= now { a.step(now) }
            if now >= nextBig {
                big.append(big.toolUse("Bash", input: ["command": "make"]), big.toolResult(Soak.text(Soak.size())), big.reply("Still going."))
                nextBig = now.addingTimeInterval(20)
            }
            sample?(now)
            pause(0.02)
        }
    }

    let warmup = min(30, max(10, minutes * 6))
    note("warming up for \(Int(warmup)) s")
    drive(until: Date().addingTimeInterval(warmup))

    var samples: [Sample] = []
    var origin: Date?
    var nextSample = Date()
    let psBefore = psCPU(app.pid)
    let linesBefore = agents.reduce(0) { $0 + $1.lines }, bytesBefore = agents.reduce(0) { $0 + $1.bytes }
    drive(until: Date().addingTimeInterval(minutes * 60)) { now in
        guard now >= nextSample, let u = app.usage() else { return }
        let start = origin ?? now
        origin = start
        samples.append(Sample(t: now.timeIntervalSince(start), cpu: u.cpu, footprint: Double(u.footprint) / 1_048_576))
        nextSample = now.addingTimeInterval(Soak.sampleEvery)
    }
    let lines = agents.reduce(0) { $0 + $1.lines } - linesBefore, bytes = agents.reduce(0) { $0 + $1.bytes } - bytesBefore
    let psAfter = psCPU(app.pid)
    let psUsed: Double? = psBefore.flatMap { before in psAfter.map { $0 - before } }

    if let path = ProcessInfo.processInfo.environment["MUSTER_SOAK_SAMPLES"] {
        // Every sample as CSV, for looking at the shape of a run rather than its summary.
        let rows = samples.map { String(format: "%.1f,%.4f,%.3f", $0.t, $0.cpu, $0.footprint) }
        try? (["seconds,cpu_seconds,footprint_mb"] + rows).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    section("Soak")
    guard app.alive, samples.count >= 3, let first = samples.first, let last = samples.last else {
        check(false, "the app stays up for the whole soak", app.exitDescription)
        app.stop()
        fx.cleanup()
        summary(started, "")
    }
    let avg = (last.cpu - first.cpu) / max(1, last.t - first.t) * 100
    let peakCPU = zip(samples, samples.dropFirst()).map { ($1.cpu - $0.cpu) / max(0.001, $1.t - $0.t) * 100 }.max() ?? 0
    let foot = samples.map(\.footprint)
    let quarter = max(1, samples.count / 4)
    let growth = median(Array(foot.suffix(quarter))) - median(Array(foot.prefix(quarter)))
    let (slope, r2) = trend(samples)
    // Start-up settling looks like growth in a short run; a 30-minute run stays flat
    // after its first minute. So growth is only judged on runs of 5 minutes or more.
    let judged = minutes >= 5
    let steady = slope > 0.25 && r2 > 0.5 && growth > 1
    let finalState = app.state()

    print(String(format: "  %d min · 10 agents + one 500 MB transcript · %d samples every %.0f s · %d lines (%.1f MB) appended",
                 Int(minutes.rounded()), samples.count, Soak.sampleEvery, lines, Double(bytes) / 1_048_576))
    print("                     measured                          limit")
    print(String(format: "  CPU, one core      avg %.2f %%   peak %.1f %%            avg ≤ %.1f %%", avg, peakCPU, Soak.cpuLimit))
    print(String(format: "  Footprint          %.1f–%.1f MB, avg %.1f            ≤ %.0f MB", foot.min() ?? 0, foot.max() ?? 0,
                 foot.reduce(0, +) / Double(foot.count), Soak.footprintLimit))
    print(String(format: "  Footprint trend    %+.2f MB/min, R² %.2f, %+.1f MB    %@", slope, r2, growth,
                 judged ? "no steady growth" : "not judged under 5 min"))
    if let psUsed {
        print(String(format: "  (cross-check: ps counts %.2f s of CPU over the run, proc_pid_rusage %.2f s)", psUsed, last.cpu - first.cpu))
    }
    check(avg <= Soak.cpuLimit, "average CPU stays at or under \(Soak.cpuLimit) % of one core", String(format: "%.2f %%", avg))
    check((foot.max() ?? 0) <= Soak.footprintLimit, "the footprint stays under \(Int(Soak.footprintLimit)) MB", String(format: "max %.1f MB", foot.max() ?? 0))
    if judged { check(!steady, "the footprint doesn't grow steadily", String(format: "%+.2f MB/min", slope)) }
    check(finalState?.sessions.count == 11, "all 11 sessions are still listed at the end")
    app.stop()
    wipeDefaults()
    fx.cleanup()
    summary(started, "")
}
