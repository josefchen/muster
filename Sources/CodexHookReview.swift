import Foundation
import Darwin

/// Reads Codex's own view of the installed hook. This never enables or trusts
/// anything; those actions belong to the user in Codex.
enum CodexHookReview: String {
    case unavailable, missing, disabled, needsTrust, modified, enabled

    var blocksCheck: Bool { self == .missing || self == .disabled || self == .needsTrust || self == .modified }

    static func parse(hooks result: [String: Any], config: [String: Any], path: String, command: String) -> CodexHookReview {
        let features = (config["config"] as? [String: Any])?["features"] as? [String: Any] ?? [:]
        if (features["hooks"] as? Bool ?? features["codex_hooks"] as? Bool) == false { return .disabled }
        guard let entries = result["data"] as? [[String: Any]] else { return .unavailable }
        guard entries.allSatisfy({ ($0["errors"] as? [Any] ?? []).isEmpty }) else { return .unavailable }
        let own = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter {
            guard let source = $0["sourcePath"] as? String else { return false }
            return URL(fileURLWithPath: source).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                && $0["eventName"] as? String == "permissionRequest" && $0["command"] as? String == command
        }
        guard !own.isEmpty else { return .missing }
        if own.contains(where: { $0["trustStatus"] as? String == "modified" }) { return .modified }
        if own.contains(where: { $0["trustStatus"] as? String == "untrusted" }) { return .needsTrust }
        if own.contains(where: { $0["enabled"] as? Bool == false }) { return .disabled }
        guard own.allSatisfy({ $0["enabled"] as? Bool == true && ["trusted", "managed"].contains($0["trustStatus"] as? String ?? "") }) else { return .unavailable }
        return .enabled
    }

    /// Run on a utility queue, only while setup is visible or explicitly checked.
    /// Bounds both the process lifetime and the amount of output we retain.
    static func read(executable: String, hookPath: String, command: String, home: String, timeout: TimeInterval = 5) -> CodexHookReview {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = (hookPath as NSString).deletingLastPathComponent
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Reap only our child, never Codex's existing desktop/app-server process.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        // A client that exits between handshake messages must not SIGPIPE Muster.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { return .unavailable }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(min(5, max(0.05, timeout)))
        func send(_ value: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: value) else { return false }
            do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])); return true } catch { return false }
        }
        func result(_ id: Int) -> [String: Any]? {
            while Date() < deadline {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    buffer.removeSubrange(...end)
                    guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if d["id"] as? Int == id { return d["result"] as? [String: Any] }
                    continue
                }
                guard buffer.count < 1 << 20 else { return nil }
                var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let waited = poll(&fd, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000)))
                guard waited > 0 else { return nil }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let n = Darwin.read(fd.fd, &bytes, bytes.count)
                guard n > 0 else { return nil }
                buffer.append(contentsOf: bytes.prefix(n))
            }
            return nil
        }
        guard send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "muster_setup", "version": "1"],
                    "capabilities": ["experimentalApi": true, "explicitGatewayOauth": true]]]), result(1) != nil,
              send(["method": "initialized"]),
              send(["id": 2, "method": "hooks/list", "params": ["cwds": [home]]]), let hooks = result(2),
              send(["id": 3, "method": "config/read", "params": [:]]), let config = result(3) else { return .unavailable }
        return parse(hooks: hooks, config: config, path: hookPath, command: command)
    }
}
