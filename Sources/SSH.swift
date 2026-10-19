import Foundation

struct SSHHost: Codable, Equatable, Identifiable {
    let name: String
    var enabled = false
    var id: String { name }

    var codexHostID: String {
        let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return "remote-ssh-discovered:" + (name.addingPercentEncoding(withAllowedCharacters: characters) ?? name)
    }

    static func valid(_ name: String) -> Bool {
        let parts = name.split(separator: "@", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") }
            && name.utf8.count <= 128
            && name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:").contains($0) }
    }

    /// Explicit aliases only. Reading config never connects or reads key files.
    static func discover(home: String) -> [String] {
        let directory = home + "/.ssh"
        var visited: Set<String> = [], names: Set<String> = []
        let words = try! NSRegularExpression(pattern: #"#.*|"[^"]*"|'[^']*'|[^\s#]+"#)
        func read(_ path: String, depth: Int) {
            guard depth < 8, visited.count < 64, visited.insert(path).inserted,
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for line in content.components(separatedBy: .newlines) {
                let range = NSRange(line.startIndex..., in: line)
                let tokens = words.matches(in: line, range: range).compactMap { Range($0.range, in: line).map { String(line[$0]) } }
                    .prefix { !$0.hasPrefix("#") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                guard let key = tokens.first?.lowercased() else { continue }
                if key == "host" { names.formUnion(tokens.dropFirst().filter(valid)) }
                if key == "include" {
                    for token in tokens.dropFirst() {
                        let expanded = token.hasPrefix("~/") ? home + token.dropFirst() : token
                        let pattern = expanded.hasPrefix("/") ? expanded : directory + "/" + expanded
                        var matches = glob_t()
                        if glob(pattern, 0, nil, &matches) == 0 {
                            for i in 0..<min(Int(matches.gl_pathc), 64) {
                                if let value = matches.gl_pathv[i] { read(String(cString: value), depth: depth + 1) }
                            }
                        }
                        globfree(&matches)
                    }
                }
            }
        }
        read(directory + "/config", depth: 0)
        var aliases: [String: String] = [:]
        for name in names.sorted() {
            if aliases[name.lowercased()] == nil || name == name.lowercased() { aliases[name.lowercased()] = name }
        }
        return aliases.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct SSHFrame: Decodable {
    let version: Int
    let hostname: String
    let user: String
    let sessions: [Entry]
    let errors: [String]
    let limited: Bool

    enum CodingKeys: String, CodingKey { case version = "protocol", hostname, user, sessions, errors, limited }

    struct Entry: Decodable {
        let agent: String
        let sid: String
        let status: String
        let since: Double
        var title: String?
        var project: String?
        var asking: String?
        var lastActivity: Double?

        func session(host: String) -> Session? {
            guard let agent = Agent(rawValue: agent), !sid.isEmpty, sid.utf8.count <= 256,
                  since.isFinite, since >= 0 else { return nil }
            let states: [String: Status] = ["needsYou": .needsYou, "working": .working, "done": .done,
                                             "idle": .idle, "error": .error, "blocked": .blocked]
            guard let status = states[status] else { return nil }
            var session = Session(agent: agent, sid: sid, status: status, since: Date(timeIntervalSince1970: since),
                                  title: String((title ?? "").prefix(80)), project: String((project ?? "").prefix(4096)), appID: "")
            session.remoteHost = host
            session.asking = asking.map { String($0.prefix(240)) }
            if let lastActivity, lastActivity.isFinite, lastActivity >= 0 { session.lastActivity = Date(timeIntervalSince1970: lastActivity) }
            return session
        }
    }

    static func decode(_ data: Data) -> SSHFrame? {
        guard data.count <= 4 << 20, let frame = try? JSONDecoder().decode(Self.self, from: data),
              frame.version == 1, frame.sessions.count <= 500 else { return nil }
        return frame
    }
}

/// One private SSH process per enabled host. No passwords, agent forwarding,
/// interactive trust prompts, shared control sockets or transcript files on disk.
final class SSHStream {
    private let queue = DispatchQueue(label: "muster.ssh.stream", qos: .utility)
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorPipe: Pipe?
    private var buffer = Data()
    private var errorBytes = Data()
    var onFrame: ((SSHFrame) -> Void)?
    var onExit: ((String) -> Void)?

    static func command(_ script: String) -> String { "python3 -u -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func start(host: String, script: String, executable: String = "/usr/bin/ssh") {
        queue.async { [weak self] in
            guard let self, self.process == nil, SSHHost.valid(host) else { return }
            let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=10",
                           "-o", "ServerAliveCountMax=2", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
                           "-o", "ControlMaster=no", "-o", "ControlPath=none", "--", host, Self.command(script)]
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = stderr
            self.process = p; self.input = stdin; self.output = stdout; self.errorPipe = stderr
            self.buffer = Data(); self.errorBytes = Data()
            stdout.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                self?.queue.async { [weak self, weak p] in
                    guard let self, let p, self.process === p else { return }
                    self.buffer.append(bytes)
                    guard self.buffer.count <= 4 << 20 else { self.fail(p, "The remote helper sent too much data."); return }
                    while let end = self.buffer.firstIndex(of: 10) {
                        let line = Data(self.buffer[..<end])
                        self.buffer.removeSubrange(...end)
                        guard let frame = SSHFrame.decode(line) else { self.fail(p, "The remote helper returned an unreadable summary."); return }
                        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
                    }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                self?.queue.async { [weak self, weak p] in
                    guard let self, let p, self.process === p else { return }
                    self.errorBytes.append(bytes.prefix(max(0, 4096 - self.errorBytes.count)))
                }
            }
            p.terminationHandler = { [weak self, weak p] _ in
                self?.queue.async { [weak self, weak p] in
                    guard let self, let p, self.process === p else { return }
                    let error = String(decoding: self.errorBytes, as: UTF8.self)
                    let reason = error.contains("Host key verification failed") ? "Connect in Terminal once to trust this host."
                        : error.contains("Permission denied") ? "SSH access was denied. Check this host in Terminal."
                        : error.contains("python3") && error.contains("not found") ? "This host needs Python 3."
                        : "SSH disconnected. Retrying…"
                    self.clear()
                    DispatchQueue.main.async { [weak self] in self?.onExit?(reason) }
                }
            }
            do { try p.run() }
            catch { self.clear(); DispatchQueue.main.async { [weak self] in self?.onExit?("Couldn't start SSH.") } }
        }
    }

    func stop() {
        queue.async { [self] in
            guard let p = process else { return }
            self.clear()
            self.terminate(p)
        }
    }

    private func fail(_ p: Process, _ reason: String) {
        clear()
        terminate(p)
        DispatchQueue.main.async { [weak self] in self?.onExit?(reason) }
    }

    private func terminate(_ p: Process) {
        if p.isRunning { p.terminate() }
        queue.asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }

    private func clear() {
        output?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil; output = nil; errorPipe = nil; process = nil
        buffer = Data(); errorBytes = Data()
    }
}
