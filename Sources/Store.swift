import AppKit
import CoreServices

/// Owns the session list. Rescans on file-system events from the apps' own
/// folders (coalesced) plus a slow timer for time-based transitions, on a
/// background queue; delivers sorted snapshots on the main thread. Readers are
/// told which directories changed, so a scan re-reads only those.
final class Store {
    static let shared = Store()

    static let staleWorking: TimeInterval = 20 * 60   // "working" this quiet is shown as idle
    static let tick: TimeInterval = 5                 // for permission waits and staleness
    static let minInterval: TimeInterval = 1          // agents write constantly; one rescan a second is plenty
    static let fullPass: TimeInterval = 30            // re-read everything now and then, in case an event went missing

    private(set) var sessions: [Session] = []
    private(set) var sources: [Agent: SourceState] = [:]
    private var observers: [([Session]) -> Void] = []

    private let queue = DispatchQueue(label: "muster.scan", qos: .utility)
    private let claude = ClaudeReader()
    private let codex = CodexReader()
    private let cursor = CursorReader()
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var timer: Timer?
    private var pending = false
    private var changes = Changes.all                 // since the last scan; the first one reads everything
    private var lastFull = Date()
    private var scanned: Set<Agent> = []              // readers on during the last scan
    private var lastScan = Date.distantPast
    private var lastFound: [Session] = []
    private var opened: [String: Double]
    private var firstRun: Bool

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: "opened") as? [String: Double]
        opened = saved ?? [:]
        firstRun = saved == nil
    }

    func observe(_ f: @escaping ([Session]) -> Void) {
        observers.append(f)
        f(sessions)
    }

    /// `--demo`: sample sessions instead of your own, for screenshots and recordings.
    static let demo = CommandLine.arguments.contains("--demo")

    func start() {
        if Self.demo {
            sources = [.claude: .ok(3), .codex: .ok(2), .cursor: .ok(2)]
            if !Demo.autoplay { Prompts.shared.addDemoPrompt() }
            publish(Session.samples)
            return
        }
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in self?.rescan() }
        rescan()
    }

    func rescan() {
        guard !pending, !Self.demo else { return }
        pending = true
        let wait = Self.minInterval - Date().timeIntervalSince(lastScan)
        guard wait <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.pending = false
                self?.rescan()
            }
            return
        }
        lastScan = Date()
        if lastScan.timeIntervalSince(lastFull) >= Self.fullPass { changes.full = true }
        if changes.full {
            lastFull = lastScan
            watch()   // a folder that appeared since launch gets watched too
        }
        let enabled = Settings.enabledAgents
        let fresh = enabled.subtracting(scanned)          // just turned on: it missed its events
        scanned = enabled
        let changed = changes
        changes = Changes()
        queue.async { [weak self] in
            guard let self else { return }
            let found: [Session] = autoreleasepool {
                let now = Date()
                let since = { (a: Agent) in fresh.contains(a) ? Changes.all : changed }
                var all: [Session] = []
                if enabled.contains(.claude) { all += self.claude.scan(now: now, changes: since(.claude)) }
                if enabled.contains(.codex) { all += self.codex.scan(now: now, changes: since(.codex)) }
                if enabled.contains(.cursor) { all += self.cursor.scan(now: now, changes: since(.cursor)) }
                return all.compactMap { s in
                    var s = s
                    if s.status == .working, now.timeIntervalSince(s.since) > Self.staleWorking { s.status = .idle }
                    if s.status.section == .recent, now.timeIntervalSince(s.since) > recentWindow { return nil }
                    return s
                }
            }
            if changed.full { malloc_zone_pressure_relief(nil, 0) }
            let sources: [Agent: SourceState] = [.claude: self.claude.state, .codex: self.codex.state, .cursor: self.cursor.state]
            DispatchQueue.main.async {
                self.pending = false
                self.sources = sources
                self.publish(found)
                if !self.changes.isEmpty { self.rescan() }   // events that arrived mid-scan
            }
        }
    }

    /// A prompt arrived or was answered: re-sort without rescanning.
    func refreshPrompts() { publish(lastFound) }

    /// Opening a session marks it read.
    func markOpened(_ s: Session) {
        guard !Self.demo else { return }
        opened[s.id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(opened, forKey: "opened")
        publish(sessions)
    }

    private func publish(_ found: [Session]) {
        lastFound = found
        if !Self.demo { Prompts.shared.resolve(with: found) }
        if firstRun {
            // Everything already finished before Muster was installed counts as read.
            firstRun = false
            let now = Date().timeIntervalSince1970
            for s in found where s.status == .done { opened[s.id] = now }
            UserDefaults.standard.set(opened, forKey: "opened")
        }
        let cutoff = Date().timeIntervalSince1970 - 86400
        opened = opened.filter { $0.value > cutoff }
        var next = found.map { s -> Session in
            var s = s
            s.unread = s.status == .done && (opened[s.id] ?? 0) < s.since.timeIntervalSince1970
            if let p = Prompts.shared.prompt(for: s) {
                s.promptID = p.id
                s.status = .needsYou
                s.fault = nil
            }
            return s
        } + orphanPrompts(found)
        next.sort { a, b in a.status != b.status ? a.status < b.status : a.since > b.since }
        guard next != sessions else { return }
        sessions = next
        observers.forEach { $0(next) }
    }

    /// A prompt from a session no scan has seen yet still gets a row.
    private func orphanPrompts(_ found: [Session]) -> [Session] {
        Prompts.shared.pending.values.filter { p in !found.contains { $0.agent == p.agent && $0.sid == p.sessionID } }.map { p in
            var s = Session(agent: p.agent, sid: p.sessionID, status: .needsYou, since: p.created,
                            title: "", project: p.project, appID: "")
            s.promptID = p.id
            return s
        }
    }

    /// Watches the readers' folders that exist. Each event names a directory whose
    /// entries or files changed; the next scan re-reads just those.
    private func watch() {
        let existing = (claude.watchPaths + codex.watchPaths + cursor.watchPaths).filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != watched else { return }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        watched = existing
        guard !existing.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let store = Unmanaged<Store>.fromOpaque(info).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                                               | kFSEventStreamEventFlagRootChanged)
            let subtree = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            for i in 0..<count {
                if flags[i] & lost != 0 { store.changes.full = true; continue }
                store.changes.add(String(cString: names[i]), subtree: flags[i] & subtree != 0)
            }
            store.rescan()
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }
}

enum Opener {
    /// Brings up the session where it runs. A CLI agent in a terminal or editor brings
    /// that app forward; otherwise the agent's own app opens it: Claude via its
    /// continue / needs-input link (local_ ids only), Codex by thread, Cursor in the
    /// Agents window.
    static func open(_ s: Session) {
        guard !Store.demo else { return }
        Store.shared.markOpened(s)
        Stats.record(.jumped)
        if E2E.on { E2E.opening = s }
        if let host = ProcessHost.app(running: s), !s.agent.bundleIDs.contains(host.bundleIdentifier ?? "") {
            host.activate()
            return
        }
        switch s.agent {
        case .claude:
            if !s.appID.isEmpty {
                let path = s.status == .needsYou ? "needs-input" : "continue"
                if openURL("claude://code/\(path)?session=\(encode(s.appID))&source=muster") { return }
            }
        case .codex:
            if openURL("codex://threads/\(encode(s.sid))") { return }
        case .cursor:
            if openURL("cursor://anysphere.cursor-deeplink/agent?id=\(encode(s.sid))") { return }
        }
        activate(s.agent)
    }

    static func activate(_ agent: Agent) {
        if E2E.on { return E2E.record("activate:" + agent.rawValue) }
        guard let url = agent.bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func openURL(_ s: String) -> Bool {
        if E2E.on { E2E.record(s); return true }
        guard let url = URL(string: s), NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?/"))) ?? s
    }
}

/// Finds the app hosting a live CLI agent: the process named after the agent whose
/// working directory is the session's project, walked up to its first regular app.
enum ProcessHost {
    static func app(running s: Session) -> NSRunningApplication? {
        if E2E.on { return nil }
        let names: Set<String> = s.agent == .claude ? ["claude"] : s.agent == .codex ? ["codex"] : []
        guard !names.isEmpty, !s.project.isEmpty else { return nil }
        for pid in allPIDs() where names.contains(name(pid)) && cwd(pid) == s.project {
            var p: pid_t? = pid
            while let q = p, q > 1 {
                if let app = NSRunningApplication(processIdentifier: q), app.activationPolicy == .regular { return app }
                p = parent(q)
            }
        }
        return nil
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, n))))
    }

    private static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, 256)
        return String(cString: buf)
    }

    private static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
