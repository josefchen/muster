import Foundation

/// Muster and Agent Relay sharing one approval hook on this Mac.
///
/// Two blocking hooks on the same request hold the agent until both return, so answering in
/// one left it waiting for the other, and Relay's installer removes Muster's hooks to avoid
/// that. Instead one hook (remote_approvals.py's runner, the same one SSH hosts use) sends
/// each request to both. The first answer goes back to the agent and the other copy is
/// withdrawn. The runner reaches Muster over HTTP, reading the port and token from a private
/// file Muster rewrites, so the agent's hook definition never changes when the port moves.
enum LocalShare {
    static var folder: String { home + "/Library/Application Support/Muster/approvals" }
    private static var endpoint: String { folder + "/muster.json" }

    /// The runner's handler for this agent: `<python> '<folder>/hook.py' local <agent> <event>`.
    static func isRunner(_ h: [String: Any], _ agent: Agent) -> Bool {
        guard let command = h["command"] as? String else { return false }
        return command.contains(folder + "/hook.py") && command.contains(" local \(agent.rawValue) ")
    }

    /// Agent Relay's own Python client, on this Mac or a Linux host.
    static func isRelay(_ h: [String: Any]) -> Bool {
        guard let command = h["command"] as? String else { return false }
        return command.contains("/AgentRelay/connector/hook-client.py") || command.contains("/agent-relay/connector/hook-client.py")
    }

    private static func handlers(_ path: String) -> [[String: Any]] {
        guard let hooks = SettingsFile.read(path)?["hooks"] as? [String: Any] else { return [] }
        return hooks.values.flatMap { value in
            (value as? [Any] ?? []).flatMap { (($0 as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
        }
    }

    /// Relay answers this agent's approvals with its own hook.
    static func relayHolds(_ path: String) -> Bool { handlers(path).contains(where: isRelay) }
    /// The shared hook is installed for this agent.
    static func shared(_ agent: Agent, _ path: String) -> Bool { handlers(path).contains { isRunner($0, agent) } }

    /// Writes the port and token the runner reads. Only while sharing, so it's never left
    /// behind for nothing.
    static func publish(port: UInt16, token: String) {
        guard FileManager.default.fileExists(atPath: folder + "/hook.py"), !token.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["port": Int(port), "token": token], options: [.sortedKeys]) else { return }
        let staged = endpoint + ".tmp"
        guard FileManager.default.createFile(atPath: staged, contents: body, attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: endpoint), withItemAt: URL(fileURLWithPath: staged))
        if !FileManager.default.fileExists(atPath: endpoint) { try? FileManager.default.moveItem(atPath: staged, toPath: endpoint) }
    }

    /// Installs the shared hook for Claude Code and Codex together (Relay's installer
    /// sets up both), moving Relay's hook into it and replacing Muster's direct ones.
    static func enable(python: String?, script: URL, port: UInt16, token: String) throws {
        try run(python: python, script: script, ["--install-approvals", "--local", "--share-with-agent-relay"])
        publish(port: port, token: token)
    }

    /// Removes the shared hook and puts Relay's own back exactly as it was.
    static func disable(python: String?, script: URL) throws {
        try run(python: python, script: script, ["--remove-approvals", "--local"])
        try? FileManager.default.removeItem(atPath: endpoint)
    }

    /// The Python Relay's hook (or the shared one) already runs with, which is known to work here.
    static func relayPython(_ paths: [String]) -> String? {
        for path in paths {
            for h in handlers(path) {
                guard let command = h["command"] as? String, isRelay(h) || command.contains(folder + "/hook.py"),
                      let first = command.split(separator: " ").first else { continue }
                let python = first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) { return python }
            }
        }
        return nil
    }

    private static func run(python: String?, script: URL, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python ?? "/usr/bin/python3")
        p.arguments = [script.path] + arguments + ["--home", home]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        p.environment = environment
        let errors = Pipe()
        p.standardError = errors
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "Muster", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                message.isEmpty ? "Couldn't share approvals with Agent Relay." : message.replacingOccurrences(of: "Muster: ", with: "")])
        }
    }
}
