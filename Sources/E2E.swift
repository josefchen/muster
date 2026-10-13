import AppKit
import Network

/// End-to-end test mode, driven by scripts/e2e.sh. Asked for with MUSTER_E2E=1 and
/// honoured only in the dev.muster.e2e bundle reading a MUSTER_HOME fixture folder
/// on ports of its own; anything else that could reach your real agents makes the
/// app quit instead. While on, opening a session is logged rather than done, and
/// notifications, update checks, login items and the installer stay off. Headless
/// runs (the default) also keep panels transparent and click-through and register
/// no global keys; MUSTER_E2E_UI=1 shows everything for the keystroke tests.
///
/// A loopback control channel on MUSTER_E2E_PORT reports state and drives the same
/// code paths keys, clicks and answers use:
///   GET  /state                                       sessions, prompts, sources, panels
///   POST /answer {prompt, answer: allow|always|deny|option, option}
///   POST /hooks  {agent, install}
///   POST /open   {id} or {url: "muster://…"}
///   POST /ui     {action, …}                           see `act`
///   POST /quit
enum E2E {
    static let bundleID = "dev.muster.e2e"
    private static let env = ProcessInfo.processInfo.environment
    private static let realPorts: ClosedRange<UInt16> = 47621...47640

    static let on: Bool = {
        guard env["MUSTER_E2E"] == "1" else { return false }
        if let why = refusal {
            FileHandle.standardError.write(Data("Muster: e2e mode refused, \(why).\n".utf8))
            exit(78)
        }
        return true
    }()
    static let ui = on && env["MUSTER_E2E_UI"] == "1"
    /// Panels on screen, key focus and global shortcuts: always, except in headless e2e runs.
    static var showsUI: Bool { !on || ui }

    private static var refusal: String? {
        guard Bundle.main.bundleIdentifier == bundleID else { return "the bundle id must be \(bundleID)" }
        guard let fixture = env["MUSTER_HOME"], !fixture.isEmpty, fixture == home else { return "MUSTER_HOME must name a fixture folder" }
        let real = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        guard canonical(fixture) != canonical(real) else { return "MUSTER_HOME is your real home folder" }
        guard env["CLAUDE_CONFIG_DIR"] == nil, env["CODEX_HOME"] == nil else { return "CLAUDE_CONFIG_DIR and CODEX_HOME must be unset" }
        guard base != nil else { return "MUSTER_PORT must keep clear of \(realPorts.lowerBound)-\(realPorts.upperBound)" }
        guard let control = env["MUSTER_E2E_PORT"].flatMap(UInt16.init), control >= 1024, !realPorts.contains(control)
        else { return "MUSTER_E2E_PORT must name a free port" }
        return nil
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The hook server's ports: MUSTER_PORT and the 19 after it, never the real app's.
    static var ports: ClosedRange<UInt16>? { on ? base.map { $0...$0 + 19 } : nil }
    private static let base: UInt16? = {
        guard let text = env["MUSTER_PORT"] else { return 47661 }
        guard let p = UInt16(text), p >= 1024, p <= UInt16.max - 19, !(p...p + 19).overlaps(realPorts) else { return nil }
        return p
    }()

    // MARK: seams

    /// Modifier keys the switcher sees as held: set over the control channel in headless runs.
    static var held: NSEvent.ModifierFlags = []
    static var modifierFlags: NSEvent.ModifierFlags { on && !ui ? held : NSEvent.modifierFlags }

    /// The agent app taken to be frontmost, for prompts that let go when you look at it.
    static var front: Agent?

    /// The session Opener is opening, for the log line.
    static var opening: Session?
    private static var opened = 0

    /// What Opener would have opened: a deep link, or "activate:<agent>".
    static func record(_ url: String) {
        var entry: [String: Any] = ["url": url, "at": Date().timeIntervalSince1970]
        if let s = opening {
            entry["agent"] = s.agent.rawValue
            entry["sid"] = s.sid
            entry["status"] = name(s.status)
        }
        opening = nil
        opened += 1
        guard let path = env["MUSTER_E2E_LOG"], var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        fh.seekToEndOfFile()
        fh.write(line)
        try? fh.close()
    }

    private static let panels = NSHashTable<GlassPanel>.weakObjects()

    /// Every glass panel checks in here; headless runs keep it invisible to the pointer.
    static func adopt(_ panel: GlassPanel) {
        guard on else { return }
        panels.add(panel)
        if !showsUI {
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
        }
    }

    // MARK: control channel

    private static var listener: NWListener?

    static func start() {
        guard on, listener == nil else { return }
        trapCrashes()
        guard let number = env["MUSTER_E2E_PORT"].flatMap(UInt16.init), let port = NWEndpoint.Port(rawValue: number) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        guard let l = try? NWListener(using: params) else { exit(75) }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            read(c, Data())
        }
        l.stateUpdateHandler = { state in
            if case .failed = state { FileHandle.standardError.write(Data("Muster: e2e control port is taken.\n".utf8)); exit(75) }
        }
        l.start(queue: .main)
        listener = l
    }

    /// A crash ends the process with 128 + signal and a backtrace on stderr, so the
    /// driver sees it and no crash report dialog appears mid-run.
    private static func trapCrashes() {
        for sig in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
            signal(sig) { s in
                let note: StaticString = "Muster e2e: crashed\n"
                note.withUTF8Buffer { _ = write(2, $0.baseAddress, $0.count) }
                withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 48) { frames in
                    backtrace_symbols_fd(frames.baseAddress, backtrace(frames.baseAddress, 48), 2)
                }
                _exit(128 + s)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let body: [String: Any]

        /// A complete request, or nil while more bytes are due.
        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let parts = head.first?.split(separator: " ") ?? []
            var length = 0
            for line in head.dropFirst() where line.lowercased().hasPrefix("content-length:") {
                length = max(0, min(Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0, 16 << 20))
            }
            let start = end.upperBound
            guard parts.count >= 2, data.endIndex - start >= length else { return nil }
            method = String(parts[0])
            path = String(parts[1].split(separator: "?").first ?? "")
            let bytes = data[start..<start + length]
            body = bytes.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        }
    }

    private static func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let r = Request(buffer) {
                let (status, out) = route(r)
                let body = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data("{}".utf8)
                let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\n" +
                    "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    c.cancel()
                    if r.path == "/quit" { NSApp.terminate(nil) }
                })
            } else if !done, error == nil, buffer.count < 32 << 20 {
                read(c, buffer)
            } else {
                c.cancel()
            }
        }
    }

    private static func route(_ r: Request) -> (Int, [String: Any]) {
        switch (r.method, r.path) {
        case ("GET", "/state"):
            return (200, state())
        case ("POST", "/answer"):
            guard let id = (r.body["prompt"] as? String).flatMap(UUID.init(uuidString:)), let p = Prompts.shared.pending[id] else {
                return (404, ["error": "no such prompt"])
            }
            guard let a = answer(r.body) else { return (400, ["error": "unknown answer"]) }
            Prompts.shared.answer(p, a)
            return (200, ["ok": Prompts.shared.pending[id] == nil])
        case ("POST", "/hooks"):
            guard let agent = (r.body["agent"] as? String).flatMap(Agent.init(rawValue:)) else { return (400, ["error": "unknown agent"]) }
            var out: [String: Any] = [:]
            do {
                try (r.body["install"] as? Bool ?? true) ? HookInstaller.install(agent) : HookInstaller.uninstall(agent)
            } catch {
                out["error"] = error.localizedDescription
            }
            out["installed"] = HookInstaller.isInstalled(agent)
            return (200, out)
        case ("POST", "/open"):
            if let url = r.body["url"] as? String {
                handle(url)
                return (200, ["ok": true])
            }
            guard let s = Store.shared.sessions.first(where: { $0.id == r.body["id"] as? String }) else { return (404, ["error": "no such session"]) }
            Opener.open(s)
            return (200, ["ok": true])
        case ("POST", "/ui"):
            let error = act(r.body)
            return error.map { (400, ["error": $0]) } ?? (200, ["ok": true])
        case ("POST", "/quit"):
            return (200, ["ok": true])
        default:
            return (404, ["error": "unknown route"])
        }
    }

    private static func answer(_ d: [String: Any]) -> Answer? {
        switch d["answer"] as? String {
        case "allow": return .allow
        case "always": return .alwaysAllow
        case "deny": return .deny
        case "option": return (d["option"] as? Int).map(Answer.option)
        default: return nil
        }
    }

    /// muster:// links, through the app's own Apple Event handler.
    private static func handle(_ url: String) {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyDirectObject))
        (NSApp.delegate as? AppDelegate)?.handleURL(event, reply: NSAppleEventDescriptor.null())
    }

    /// The same calls the global shortcuts, answer keys, clicks and typing end in.
    ///   next | previous | up | down | cancel | search    a shortcut, as Carbon delivers it
    ///   hold {flags: [option, control, shift, command]}  modifiers the switcher sees held
    ///   release                                          let them go
    ///   answer {answer, option}                          ⌥↩ ⌥⇧↩ ⌥⌫ ⌥1–9 (switcher, deck or alert)
    ///   click {panel: switcher|deck, row}                a click on a row
    ///   type {text}                                      the deck's search field
    ///   key {key: return|escape|up|down|cmd+1…cmd+9}     a key in the deck
    ///   alert {part: open|dismiss}                       a click on the alert or its close button
    ///   front {agent}                                    an agent's app comes to the front (null: none)
    ///   rescan
    private static func act(_ d: [String: Any]) -> String? {
        let action = d["action"] as? String ?? ""
        let shortcuts: [String: Hotkeys.Action] = ["next": .next, "previous": .previous, "up": .up, "down": .down,
                                                   "cancel": .cancel, "search": .search]
        if let a = shortcuts[action] {
            Hotkeys.shared.handler?(a)
            return nil
        }
        switch action {
        case "hold":
            var f: NSEvent.ModifierFlags = []
            for name in d["flags"] as? [String] ?? ["option"] {
                switch name {
                case "option": f.insert(.option)
                case "control": f.insert(.control)
                case "shift": f.insert(.shift)
                case "command": f.insert(.command)
                default: return "unknown modifier \(name)"
                }
            }
            held = f
        case "release":
            held = []
        case "answer":
            guard let a = answer(d) else { return "unknown answer" }
            Hotkeys.shared.onAnswer?(a)
        case "click":
            guard let p = panel(d["panel"] as? String ?? ""), p.isVisible, let list = find(SessionList.self, in: p.content),
                  let row = d["row"] as? Int, list.items.indices.contains(row) else { return "no such row" }
            list.onClick?(row)
        case "type":
            guard let p = panel("deck"), p.isVisible, let field = find(NSTextField.self, in: p.content, where: \.isEditable) else { return "the deck is closed" }
            field.stringValue = d["text"] as? String ?? ""
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        case "key":
            guard let p = panel("deck"), p.isVisible, let field = find(NSTextField.self, in: p.content, where: \.isEditable) else { return "the deck is closed" }
            let key = d["key"] as? String ?? ""
            if key.hasPrefix("cmd+") {
                let c = String(key.dropFirst(4))
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: p.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c,
                                               isARepeat: false, keyCode: 0) else { return "bad key" }
                _ = p.performKeyEquivalent(with: e)
                return nil
            }
            let commands = ["return": #selector(NSResponder.insertNewline(_:)), "escape": #selector(NSResponder.cancelOperation(_:)),
                            "up": #selector(NSResponder.moveUp(_:)), "down": #selector(NSResponder.moveDown(_:))]
            guard let sel = commands[key] else { return "unknown key \(key)" }
            _ = field.delegate?.control?(field, textView: NSTextView(), doCommandBy: sel)
        case "alert":
            guard let p = panel("alert"), p.isVisible, let surface = p.content.subviews.first else { return "no alert" }
            let point = d["part"] as? String == "dismiss" ? NSPoint(x: 13, y: 13) : NSPoint(x: surface.bounds.midX, y: surface.bounds.midY)
            guard let e = NSEvent.mouseEvent(with: .leftMouseDown, location: surface.convert(point, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return "bad click" }
            surface.mouseDown(with: e)
        case "front":
            front = (d["agent"] as? String).flatMap(Agent.init(rawValue:))
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                                       userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        case "rescan":
            Store.shared.rescan()
        default:
            return "unknown action \(action)"
        }
        return nil
    }

    // MARK: state

    private static func name(_ s: Status) -> String {
        switch s {
        case .needsYou: return "needsYou"
        case .error: return "error"
        case .working: return "working"
        case .done: return "done"
        case .blocked: return "blocked"
        case .idle: return "idle"
        }
    }

    private static func state() -> [String: Any] {
        let sessions: [[String: Any]] = Store.shared.sessions.map { s in
            ["id": s.id, "agent": s.agent.rawValue, "sid": s.sid, "status": name(s.status), "unread": s.unread,
             "promptID": s.promptID?.uuidString ?? NSNull(), "since": s.since.timeIntervalSince1970, "appID": s.appID,
             "project": s.project, "title": s.title, "tokens": s.tokens, "fault": s.fault?.label ?? NSNull()]
        }
        let prompts: [[String: Any]] = Prompts.shared.pending.values.sorted { $0.created < $1.created }.map { p in
            var d: [String: Any] = ["id": p.id.uuidString, "agent": p.agent.rawValue, "sid": p.sessionID, "blocksNative": p.blocksNative]
            switch p.kind {
            case .permission(let tool, let summary, let always):
                d["kind"] = "permission"; d["tool"] = tool; d["summary"] = summary; d["canAlwaysAllow"] = always
            case .question(let text, let options):
                d["kind"] = "question"; d["question"] = text; d["options"] = options
            case .plan:
                d["kind"] = "plan"
            }
            return d
        }
        var sources: [String: String] = [:]
        for (agent, s) in Store.shared.sources {
            switch s {
            case .notInstalled: sources[agent.rawValue] = "notInstalled"
            case .ok(let n): sources[agent.rawValue] = "ok:\(n)"
            case .unreadable: sources[agent.rawValue] = "unreadable"
            }
        }
        return ["pid": Int(getpid()), "bundle": Bundle.main.bundleIdentifier ?? "", "home": home, "e2e": on, "ui": ui,
                "arch": arch, "hookPort": Int(Prompts.port), "sessions": sessions, "prompts": prompts, "sources": sources,
                "hooks": ["claude": HookInstaller.isInstalled(.claude), "codex": HookInstaller.isInstalled(.codex)],
                "panels": ["switcher": info("switcher"), "deck": info("deck"), "alert": info("alert")],
                "conflicts": Hotkeys.shared.conflicts.sorted(), "opened": opened]
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func panel(_ name: String) -> GlassPanel? {
        panels.allObjects.first { $0.identifier?.rawValue == "muster." + name }
    }

    private static func info(_ name: String) -> [String: Any] {
        guard let p = panel(name) else { return ["visible": false] }
        var d: [String: Any] = ["visible": p.isVisible, "key": p.isKeyWindow, "window": p.windowNumber, "frame": rect(p.frame)]
        if let list = find(SessionList.self, in: p.content) {
            d["items"] = list.items.map(\.id)
            d["selected"] = list.selected
            d["rows"] = list.items.indices.compactMap(list.rowFrame).map { rect(p.convertToScreen(list.convert($0, to: nil))) }
        } else if let row = find(SessionRow.self, in: p.content) {
            d["session"] = row.session?.id ?? NSNull()
        }
        if let field = find(NSTextField.self, in: p.content, where: \.isEditable) { d["query"] = field.stringValue }
        return d
    }

    private static func rect(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView, where ok: (T) -> Bool = { _ in true }) -> T? {
        for v in view.subviews {
            if let hit = v as? T, ok(hit) { return hit }
            if let hit = find(type, in: v, where: ok) { return hit }
        }
        return nil
    }
}
