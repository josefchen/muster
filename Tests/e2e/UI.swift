import AppKit
import ApplicationServices

// The UI layer: real keystrokes and clicks posted to the system, against the app
// with its panels on screen, checked through the control channel and the
// accessibility tree. It takes over the keyboard, pointer and screen while it runs,
// so it only runs when asked (scripts/e2e.sh --ui), never in CI.
//
// Needs, granted to the terminal it runs from:
//   Accessibility      to post key and mouse events and read the accessibility tree
//   Screen Recording   only with --baselines, to capture the panels
// and Muster itself quit, so ⌥Tab and ⌃⌥Space are free for the test app.

enum Keys {
    static let source = CGEventSource(stateID: .hidSystemState)
    static let option: CGKeyCode = 0x3A, control: CGKeyCode = 0x3B, shift: CGKeyCode = 0x38, command: CGKeyCode = 0x37
    static let tab: CGKeyCode = 0x30, space: CGKeyCode = 0x31, escape: CGKeyCode = 0x35, enter: CGKeyCode = 0x24, delete: CGKeyCode = 0x33
    static let one: CGKeyCode = 0x12
    private static var held: CGEventFlags = []
    private static let modifiers: [(CGKeyCode, CGEventFlags)] = [(option, .maskAlternate), (control, .maskControl), (shift, .maskShift),
                                                                 (command, .maskCommand)]

    private static func post(_ key: CGKeyCode, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        // A modifier on its own arrives as flagsChanged, as from a real keyboard.
        if modifiers.contains(where: { $0.0 == key }) { e.type = .flagsChanged }
        e.flags = held
        e.post(tap: .cghidEventTap)
        pause(0.03)
    }

    static func press(_ key: CGKeyCode) {
        if let m = modifiers.first(where: { $0.0 == key }) { held.insert(m.1) }
        post(key, down: true)
    }

    static func lift(_ key: CGKeyCode) {
        if let m = modifiers.first(where: { $0.0 == key }) { held.remove(m.1) }
        post(key, down: false)
    }

    static func tap(_ key: CGKeyCode) {
        post(key, down: true)
        post(key, down: false)
    }

    /// Modifiers down, the key, modifiers up in reverse.
    static func chord(_ key: CGKeyCode, _ mods: [CGKeyCode]) {
        mods.forEach(press)
        tap(key)
        mods.reversed().forEach(lift)
    }

    static func type(_ text: String) {
        for unit in text.utf16 {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                var c = unit
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e.post(tap: .cghidEventTap)
            }
            pause(0.04)
        }
    }

    /// Lets go of anything still held, whatever happened.
    static func releaseAll() {
        for (key, flag) in modifiers where held.contains(flag) { lift(key) }
    }
}

enum Pointer {
    static func move(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGEvent(mouseEventSource: Keys.source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        pause(0.08)
    }

    static func click(_ p: CGPoint) {
        move(p)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: Keys.source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            pause(0.05)
        }
    }
}

/// A Cocoa screen rectangle (origin at the main display's bottom left) in CG's
/// global coordinates (origin at its top left).
func cgRect(_ a: [Double]?) -> CGRect {
    guard let a, a.count == 4 else { return .null }
    let h = CGDisplayBounds(CGMainDisplayID()).height
    return CGRect(x: a[0], y: Double(h) - a[1] - a[3], width: a[2], height: a[3])
}

func displays() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).map(CGDisplayBounds)
}

enum AX {
    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func windows(_ pid: pid_t) -> [AXUIElement] {
        attr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    /// Every button below `e`, by its accessibility label.
    static func buttons(_ e: AXUIElement, depth: Int = 8) -> [String] {
        guard depth > 0 else { return [] }
        return children(e).flatMap { c -> [String] in
            let mine = attr(c, kAXRoleAttribute) as? String == kAXButtonRole ? [attr(c, kAXDescriptionAttribute) as? String ?? ""] : []
            return mine + buttons(c, depth: depth - 1)
        }
    }

    /// The window showing a panel: by its identifier, else by where it is.
    static func window(_ pid: pid_t, id: String, frame: CGRect) -> AXUIElement? {
        let all = windows(pid)
        if let hit = all.first(where: { attr($0, kAXIdentifierAttribute) as? String == id }) { return hit }
        return all.first { w in self.frame(w).map { abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2 } ?? false }
    }
}

final class UISuite {
    let app: App
    let fx: Fixture
    private var working: ClaudeFixture!
    private var asking: ClaudeFixture!
    private var linked: ClaudeFixture!
    private let linkedApp = "local_" + UUID().uuidString.lowercased()
    private var hookURL: (port: UInt16, path: String) = (0, "")
    private var hookHeaders: [String: String] = [:]

    init(app: App, fx: Fixture) {
        self.app = app
        self.fx = fx
    }

    func run() {
        prepare()
        switcher()
        deck()
        alert()
        screens()
    }

    private func url(_ s: [String: Any]?) -> String {
        guard let s else { return "" }
        let sid = s["sid"] as? String ?? ""
        switch s["agent"] as? String {
        case "claude":
            let appID = s["appID"] as? String ?? ""
            if appID.isEmpty { return "activate:claude" }
            return "claude://code/\(s["status"] as? String == "needsYou" ? "needs-input" : "continue")?session=\(appID)&source=muster"
        case "codex": return "codex://threads/\(sid)"
        default: return "cursor://anysphere.cursor-deeplink/agent?id=\(sid)"
        }
    }

    private func opened(_ what: String, after n: Int, _ s: [String: Any]?) {
        let start = Date()
        while Date().timeIntervalSince(start) < 2 {
            let log = fx.opened()
            if log.count > n {
                check(log[n]["url"] as? String == url(s) && log[n]["sid"] as? String == s?["sid"] as? String, what, log[n]["url"] as? String ?? "")
                return
            }
            pause(0.03)
        }
        check(false, what, "nothing opened")
    }

    private func prepare() {
        section("Setup")
        working = ClaudeFixture(fx, project: "ui-working")
        working.write(working.user("Refactor"), working.toolUse("Bash", input: ["command": "make"]))
        asking = ClaudeFixture(fx, project: "ui-asking")
        asking.write(asking.user("Choose"), asking.ask())
        linked = ClaudeFixture(fx, project: "ui-linked")
        linked.write(linked.user("Plan the Zephyr migration"), linked.reply("Planned."))
        linked.appRecord(appID: linkedApp, title: "Zephyr migration")
        expect(app, "the test sessions are listed") { [self] s in
            s.status(working.id) == "working" && s.status(asking.id) == "needsYou" && s.session(linked.id) != nil
        }
        app.post("/hooks", ["agent": "claude", "install": true])
        let settings = fx.read(".claude/settings.json").flatMap(parseJSON) as? [String: Any] ?? [:]
        let hook = ((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.first { ($0["headers"] as? [String: String])?["X-Muster-Token"] != nil }
        let u = (hook?["url"] as? String).flatMap(URLComponents.init(string:))
        hookURL = (UInt16(u?.port ?? 0), u?.path ?? "")
        hookHeaders = (hook?["headers"] as? [String: String] ?? [:]).merging(["Content-Type": "application/json"]) { a, _ in a }
        check(hookURL.port > 0, "hooks installed for the alert keys")
        // The alert would otherwise sit over the switcher tests.
        asking.append(asking.toolResult("Postgres"), asking.reply("Done."))
        expect(app, "…and nothing waiting yet") { !$0.visible("alert") }
    }

    private func switcher() {
        section("Switcher (⌥Tab)")
        guard var s = app.state() else { return }
        var pick = s.switcherPick
        var n = fx.opened().count
        Keys.press(Keys.option)
        Keys.tap(Keys.tab)
        Keys.lift(Keys.option)
        opened("a quick tap opens the most urgent session", after: n, s.session(pick[0]))
        check(until(app, within: 0.5) { $0.visible("switcher") } == nil, "…without showing the panel")

        Keys.press(Keys.option)
        Keys.tap(Keys.tab)
        expect(app, "holding ⌥ shows the switcher, key, with the live sessions first") {
            $0.visible("switcher") && $0.panel("switcher")["key"] as? Bool == true && $0.items("switcher") == pick
        }
        s = app.state() ?? s
        if let w = AX.window(app.pid, id: "muster.switcher", frame: cgRect(s.panel("switcher")["frame"] as? [Double])) {
            check(AX.buttons(w).count == pick.count, "the accessibility tree has a button per row", "\(AX.buttons(w).count) of \(pick.count)")
        } else {
            check(false, "the switcher shows up in the accessibility tree")
        }
        Keys.tap(Keys.tab)
        Keys.tap(Keys.tab)
        Keys.press(Keys.shift)
        Keys.tap(Keys.tab)
        Keys.lift(Keys.shift)
        expect(app, "Tab, Tab, ⇧Tab: the second row") { $0.selected("switcher") == 1 }
        n = fx.opened().count
        Keys.lift(Keys.option)
        opened("letting go of ⌥ opens it", after: n, s.session(pick[1]))
        expect(app, "…and closes the panel") { !$0.visible("switcher") }

        Keys.press(Keys.option)
        Keys.tap(Keys.tab)
        expect(app, "the switcher again") { $0.visible("switcher") }
        n = fx.opened().count
        Keys.tap(Keys.escape)
        expect(app, "⌥Esc closes it") { !$0.visible("switcher") }
        Keys.lift(Keys.option)
        pause(0.3)
        check(fx.opened().count == n, "…and letting go opens nothing")

        Keys.press(Keys.option)
        Keys.tap(Keys.tab)
        s = until(app) { $0.visible("switcher") } ?? s
        pick = s.items("switcher")
        let rows = s.panel("switcher")["rows"] as? [[Double]] ?? []
        n = fx.opened().count
        if rows.count > 2 {
            let r = cgRect(rows[2])
            Pointer.click(CGPoint(x: r.midX, y: r.midY))
            opened("clicking the third row opens it", after: n, s.session(pick[2]))
        } else {
            check(false, "three rows to click")
        }
        Keys.lift(Keys.option)
        expect(app, "…and the panel closes") { !$0.visible("switcher") }
    }

    private func deck() {
        section("Search (⌃⌥Space)")
        Keys.chord(Keys.space, [Keys.control, Keys.option])
        expect(app, "⌃⌥Space opens the deck with focus in the search field") { $0.visible("deck") && $0.panel("deck")["key"] as? Bool == true }
        Keys.type("zephyr")
        expect(app, "typing filters it") { [self] in $0.panel("deck")["query"] as? String == "zephyr" && $0.items("deck") == [linked.id] }
        let n = fx.opened().count
        Keys.chord(Keys.one, [Keys.command])
        opened("⌘1 opens the first match", after: n, app.state()?.session(linked.id))
        expect(app, "…and closes the deck") { !$0.visible("deck") }
        Keys.chord(Keys.space, [Keys.control, Keys.option])
        expect(app, "the deck again") { $0.visible("deck") }
        Keys.tap(Keys.escape)
        expect(app, "Esc closes it") { !$0.visible("deck") }
    }

    private func hold(_ c: ClaudeFixture) -> Pending<Response?> {
        let payload = c.permissionPayload(command: "npm run migrate", suggestions: [])
        let (port, path, headers) = (hookURL.port, hookURL.path, hookHeaders)
        return Pending { HTTP.request(port, "POST", path, headers: headers, body: json(payload), timeout: 30) }
    }

    private func alert() {
        section("Alert")
        let c = ClaudeFixture(fx, project: "ui-alert")
        c.write(c.user("Migrate"), c.toolUse("Bash", input: ["command": "npm run migrate"]))
        expect(app, "a session to prompt from") { $0.status(c.id) == "working" }
        var req = hold(c)
        expect(app, "a held permission request raises the alert, without taking focus") {
            $0.visible("alert") && $0.alertSession == c.id && $0.panel("alert")["key"] as? Bool == false
        }
        Keys.chord(Keys.enter, [Keys.option])
        var r = req.wait(3) ?? nil
        check(sameJSON(r?.body, Expect.allow), "⌥↩ allows it")
        req = hold(c)
        expect(app, "another request") { $0.visible("alert") && $0.alertSession == c.id }
        Keys.chord(Keys.delete, [Keys.option])
        r = req.wait(3) ?? nil
        check(sameJSON(r?.body, Expect.deny), "⌥⌫ denies it")

        c.append(c.ask())
        guard let s = until(app, { $0.visible("alert") && $0.alertSession == c.id }) else { return check(false, "an alert to click") }
        let f = cgRect(s.panel("alert")["frame"] as? [Double])
        let n = fx.opened().count
        Pointer.click(CGPoint(x: f.midX, y: f.midY))
        opened("clicking the alert opens the session", after: n, s.session(c.id))
        expect(app, "…and puts it away") { !$0.visible("alert") }
        c.append(c.toolResult("ok"), c.reply("Done."))
    }

    private func screens() {
        section("Screens")
        for (i, d) in displays().enumerated() {
            Pointer.move(CGPoint(x: d.midX, y: d.midY))
            Keys.press(Keys.option)
            Keys.tap(Keys.tab)
            let s = until(app) { $0.visible("switcher") }
            let f = cgRect(s?.panel("switcher")["frame"] as? [Double])
            check(d.contains(f), "display \(i + 1): the switcher opens on the screen under the pointer")
            Keys.tap(Keys.escape)
            Keys.lift(Keys.option)
            expect(app, "…and closes") { !$0.visible("switcher") }

            let c = ClaudeFixture(fx, project: "ui-screen-\(i)")
            c.write(c.user("Pick"), c.ask())
            let a = until(app) { $0.visible("alert") && $0.alertSession == c.id }
            check(d.contains(cgRect(a?.panel("alert")["frame"] as? [Double])), "display \(i + 1): so does the alert")
            c.append(c.toolResult("ok"), c.reply("Done."))
            expect(app, "…which goes once answered") { !$0.visible("alert") }
        }
    }

    /// Screenshots of the panels in demo mode, compared with saved ones (recorded
    /// on the first run; review them before committing).
    func baselines(_ dir: String) {
        section("Baselines (demo mode)")
        app.stop()
        app.arguments = ["--demo"]
        guard app.launch(hooks: false) else { return check(false, "the app starts in demo mode") }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let look = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "dark" : "light"
        Keys.press(Keys.option)
        Keys.tap(Keys.tab)
        if let s = until(app, { $0.visible("switcher") }) {
            pause(0.4)
            compare(s.panel("switcher")["window"] as? Int, "\(dir)/switcher-\(look).png", "the switcher")
        }
        Keys.tap(Keys.escape)
        Keys.lift(Keys.option)
        Keys.chord(Keys.space, [Keys.control, Keys.option])
        if let s = until(app, { $0.visible("deck") }) {
            pause(0.4)
            compare(s.panel("deck")["window"] as? Int, "\(dir)/deck-\(look).png", "the deck")
        }
        Keys.tap(Keys.escape)
    }

    private func compare(_ window: Int?, _ baseline: String, _ what: String) {
        guard let window else { return check(false, "\(what): a window to capture") }
        let shot = fx.root + "/" + (baseline as NSString).lastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(window)", shot]
        try? p.run()
        p.waitUntilExit()
        guard let now = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: shot))) ?? Data()) else {
            return check(false, "\(what): captured")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: baseline)), let then = NSBitmapImageRep(data: data) else {
            try? FileManager.default.copyItem(atPath: shot, toPath: baseline)
            return check(true, "\(what): baseline recorded", (baseline as NSString).lastPathComponent)
        }
        guard now.pixelsWide == then.pixelsWide, now.pixelsHigh == then.pixelsHigh, now.bitsPerPixel == then.bitsPerPixel,
              now.bytesPerRow == then.bytesPerRow, let a = now.bitmapData, let b = then.bitmapData else {
            return check(false, "\(what): matches its baseline", "size differs")
        }
        let count = now.bytesPerRow * now.pixelsHigh
        var total = 0
        for i in 0..<count { total += abs(Int(a[i]) - Int(b[i])) }
        let diff = Double(total) / Double(count) / 255 * 100
        check(diff < 2, "\(what): matches its baseline", String(format: "%.2f %% off", diff))
    }
}

func runUI(bundle: String, baselines: String?) -> Never {
    let started = Date()
    print("Muster e2e: UI. This posts real keystrokes and clicks; keep your hands off the keyboard and mouse until it's done.")
    guard AXIsProcessTrusted() else {
        fatal("grant Accessibility to this terminal (System Settings › Privacy & Security › Accessibility) and run again")
    }
    if baselines != nil, !CGPreflightScreenCaptureAccess() {
        fatal("--baselines needs Screen Recording for this terminal (System Settings › Privacy & Security › Screen Recording)")
    }
    for i in (1...3).reversed() {
        print("  starting in \(i)…")
        pause(1)
    }
    wipeDefaults()
    let fx = Fixture()
    _ = Headless.seed(fx)
    let app = App(bundle: bundle, fixture: fx)
    app.ui = true
    guard app.launch() else {
        appMessages(fx).forEach { note($0) }
        fx.cleanup()
        fatal("the app didn't start (\(app.exitDescription))")
    }
    guard (app.state()?.raw["conflicts"] as? [String])?.isEmpty == true else {
        app.stop()
        fx.cleanup()
        fatal("⌥Tab or ⌃⌥Space belongs to another app; quit Muster (and any other switcher) and run again")
    }
    let suite = UISuite(app: app, fx: fx)
    suite.run()
    if let dir = baselines { suite.baselines(dir) }
    Keys.releaseAll()
    app.stop()
    wipeDefaults()
    fx.cleanup()
    summary(started, "UI")
}
