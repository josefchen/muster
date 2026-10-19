import AppKit
import Combine

/// Remote summaries stay in memory. The saved preference contains host aliases
/// and opt-in switches, never keys, transcripts or SSH configuration contents.
final class RemoteSessions: ObservableObject {
    static let shared = RemoteSessions()
    static let controller: String = {
        if E2E.on || Store.demo { return "00000000-0000-0000-0000-000000000001" }
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "ssh.controller"), let id = UUID(uuidString: value) { return id.uuidString.lowercased() }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: "ssh.controller")
        return value
    }()
    private static let machineName: String = {
        let capacity = 256
        var name = [CChar](repeating: 0, count: capacity)
        guard gethostname(&name, capacity) == 0 else { return "" }
        name[capacity - 1] = 0
        return String(cString: name)
    }()
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var states: [String: String] = [:]
    @Published private(set) var issues: Set<String> = []
    private var connected: Set<String> = []
    private var streams: [String: SSHStream] = [:]
    private var snapshots: [String: [Session]] = [:]
    private var seen: [String: Date] = [:]
    private var reconnects: [String: DispatchWorkItem] = [:]
    private var delays: [String: TimeInterval] = [:]
    private var watchdog: Timer?
    private var started = false
    var onChange: (() -> Void)?

    private init() {
        guard !Store.demo, !E2E.on else { return }
        if let data = UserDefaults.standard.data(forKey: "ssh.hosts"), let saved = try? JSONDecoder().decode([SSHHost].self, from: data) {
            var names: Set<String> = []
            hosts = saved.filter { SSHHost.valid($0.name) && names.insert($0.name).inserted }.prefix(32).map { $0 }
        }
    }

    var sessions: [Session] {
        let now = Date()
        return hosts.filter(\.enabled).flatMap { host in
            (snapshots[host.name] ?? []).compactMap { original -> Session? in
                var s = original
                s.remoteOffline = !connected.contains(host.name)
                if s.status == .working, now.timeIntervalSince(max(s.since, s.lastActivity ?? s.since)) > Store.staleWorking { s.status = .idle }
                if s.status.section == .recent, now.timeIntervalSince(s.since) > recentWindow { return nil }
                return s
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        guard !Store.demo, !E2E.on else { return }
        for host in hosts where host.enabled { connect(host.name) }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.checkConnections() }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for job in self.reconnects.values { job.cancel() }
            self.reconnects.removeAll()
            for name in Array(self.streams.keys) {
                self.streams.removeValue(forKey: name)?.stop()
                self.seen[name] = nil
                self.markOffline(name, reason: "This Mac is sleeping. Reconnecting after wake.")
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for host in self.hosts where host.enabled { self.retry(host.name) }
        }
    }

    func discover() {
        guard !Store.demo, !E2E.on else { return }
        for name in SSHHost.discover(home: home) where !hosts.contains(where: { $0.name == name }) && hosts.count < 32 {
            hosts.append(SSHHost(name: name))
        }
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func add(_ input: String) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SSHHost.valid(name), hosts.count < 32 || hosts.contains(where: { $0.name == name }) else { return false }
        if !hosts.contains(where: { $0.name == name }) { hosts.append(SSHHost(name: name)) }
        setEnabled(name, true)
        return true
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        guard let i = hosts.firstIndex(where: { $0.name == name }) else { return }
        hosts[i].enabled = enabled
        persist()
        if enabled { if started { retry(name) } }
        else {
            reconnects.removeValue(forKey: name)?.cancel()
            streams.removeValue(forKey: name)?.stop()
            connected.remove(name); issues.remove(name)
            snapshots[name] = nil; seen[name] = nil; states[name] = nil
            Prompts.shared.cancelRemote(name)
            onChange?()
        }
    }

    func retry(_ name: String) {
        reconnects.removeValue(forKey: name)?.cancel()
        streams.removeValue(forKey: name)?.stop()
        markOffline(name, reason: "Reconnecting…")
        seen[name] = nil
        delays[name] = nil
        connect(name)
    }

    private func persist() {
        guard !Store.demo, !E2E.on, let data = try? JSONEncoder().encode(hosts) else { return }
        UserDefaults.standard.set(data, forKey: "ssh.hosts")
    }

    private func connect(_ name: String) {
        guard !Store.demo, !E2E.on, hosts.contains(where: { $0.name == name && $0.enabled }), streams[name] == nil else { return }
        guard let url = Bundle.main.url(forResource: "remote_sessions", withExtension: "py"),
              let approvalsURL = Bundle.main.url(forResource: "remote_approvals", withExtension: "py"),
              let reader = try? String(contentsOf: url, encoding: .utf8),
              let approvals = try? String(contentsOf: approvalsURL, encoding: .utf8) else {
            states[name] = "This build is missing the remote reader."
            issues.insert(name)
            return
        }
        let stream = SSHStream()
        streams[name] = stream
        seen[name] = Date()
        states[name] = "Connecting…"
        issues.remove(name)
        stream.onFrame = { [weak self, weak stream] frame in
            guard let self, let stream, self.streams[name] === stream else { return }
            self.delays[name] = nil
            self.receive(frame, host: name)
        }
        stream.onPrompt = { [weak self, weak stream] request in
            guard let self, let stream, self.streams[name] === stream else { return }
            self.seen[name] = Date()
            Prompts.shared.receiveRemote(request, host: name) { [weak stream] body in stream?.answer(request.id, body: body) }
        }
        stream.onCancel = { [weak self, weak stream] request in
            guard let self, let stream, self.streams[name] === stream else { return }
            self.seen[name] = Date()
            Prompts.shared.cancelRemote(name, request: request)
        }
        stream.onExit = { [weak self, weak stream] reason in
            guard let self, let stream, self.streams[name] === stream else { return }
            self.streams[name] = nil
            self.markOffline(name, reason: reason)
            let delay = min(60, (self.delays[name] ?? 1) * 2)
            self.delays[name] = delay
            let job = DispatchWorkItem { [weak self] in self?.connect(name) }
            self.reconnects[name] = job
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
        }
        stream.start(host: name, script: approvals + "\n" + reader, controller: Self.controller)
    }

    private func checkConnections() {
        for stream in streams.values { stream.heartbeat() }
        for (name, last) in seen where streams[name] != nil && Date().timeIntervalSince(last) > 40 { retry(name) }
    }

    private func receive(_ frame: SSHFrame, host: String) {
        guard hosts.contains(where: { $0.name == host && $0.enabled }) else { return }
        seen[host] = Date()
        connected.insert(host)
        if frame.errors.isEmpty && !frame.limited { issues.remove(host) } else { issues.insert(host) }
        if frame.hostname == Self.machineName && frame.user == NSUserName() {
            snapshots[host] = []
            states[host] = "This Mac is already watched locally."
        } else {
            var ids: Set<String> = []
            snapshots[host] = frame.sessions.compactMap { $0.session(host: host) }.filter { ids.insert($0.id).inserted }
            let count = sessions.filter { $0.remoteHost == host }.count
            let relay = frame.approvals == true ? " · Approvals on" : ""
            states[host] = frame.errors.first ?? (frame.limited ? "Showing the 500 most recent sessions" : "Connected · \(count) session\(count == 1 ? "" : "s")\(relay)")
        }
        onChange?()
    }

    private func markOffline(_ host: String, reason: String) {
        connected.remove(host)
        issues.insert(host)
        states[host] = reason
        var lastKnown = snapshots[host] ?? []
        for prompt in Prompts.shared.pending.values where prompt.remoteHost == host {
            var session = Session(agent: prompt.agent, sid: prompt.sessionID, status: .needsYou, since: prompt.created,
                                  title: "", project: prompt.project, appID: "")
            session.remoteHost = host
            switch prompt.kind {
            case .permission(_, let summary, _): session.asking = String(("Approve " + summary + "?").prefix(240))
            case .question(let text, _): session.asking = String(text.prefix(240))
            case .plan: session.asking = "Approve the plan?"
            }
            if let index = lastKnown.firstIndex(where: { $0.id == session.id }) {
                session.title = lastKnown[index].title
                lastKnown[index] = session
            } else { lastKnown.append(session) }
        }
        snapshots[host] = lastKnown
        Prompts.shared.cancelRemote(host)
        onChange?()
    }

    /// Fixture frames exercise the same session publishing path without SSH.
    func preview(host: String, frame: SSHFrame) {
        guard Store.demo || E2E.on, SSHHost.valid(host) else { return }
        if !hosts.contains(where: { $0.name == host }) { hosts.append(SSHHost(name: host, enabled: true)) }
        receive(frame, host: host)
    }

    func previewOffline(_ host: String) {
        guard Store.demo || E2E.on else { return }
        markOffline(host, reason: "SSH disconnected. Retrying…")
    }
}
