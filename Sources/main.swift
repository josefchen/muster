import AppKit
import ServiceManagement
import UserNotifications

enum Settings {
    private static let d = UserDefaults.standard

    static var enabledAgents: Set<Agent> { Set(Agent.allCases.filter { !d.bool(forKey: "disabled.\($0.rawValue)") }) }
    static func setEnabled(_ agent: Agent, _ on: Bool) { d.set(!on, forKey: "disabled.\(agent.rawValue)") }

    static var notifyNeedsYou: Bool {
        get { !d.bool(forKey: "mute.needsYou") }
        set { d.set(!newValue, forKey: "mute.needsYou") }
    }
    /// Off unless chosen: Claude's and Codex's own apps already say when they finish.
    static var notifyDone: Bool {
        get { d.bool(forKey: "notify.done") }
        set { d.set(newValue, forKey: "notify.done") }
    }
    enum CostDisplay: String, CaseIterable { case costAndTokens, tokens, hidden }

    static var costDisplay: CostDisplay {
        get { d.string(forKey: "costDisplay").flatMap(CostDisplay.init) ?? .costAndTokens }
        set { d.set(newValue.rawValue, forKey: "costDisplay") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            guard !E2E.on else { return }
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

/// Menu bar: one glyph, plus a count while sessions need you. Click for the deck;
/// right-click for settings and quit.
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onClick: ((NSRect?) -> Void)?
    var onSettings: (() -> Void)?
    var onUsage: (() -> Void)?
    var onTour: (() -> Void)?
    private var callout: GlassPanel?

    override init() {
        super.init()
        item.button?.image = Self.glyph()
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        if !E2E.showsUI { item.isVisible = false }
        Store.shared.observe { [weak self] in self?.render($0) }
    }

    /// The app icon's three stacked cards, as a menu bar template image.
    static func glyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            for (i, (w, alpha)) in [(10.0, 0.45), (12.0, 0.7), (14.0, 1.0)].enumerated() {
                let r = NSRect(x: (18 - w) / 2, y: 10.5 - Double(i) * 4.5, width: w, height: 4.2)
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.6, yRadius: 1.6).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Muster"
        return image
    }

    private func render(_ sessions: [Session]) {
        let waiting = sessions.filter { $0.status == .needsYou || $0.status == .error }.count
        let working = sessions.filter { $0.status == .working }.count
        guard let button = item.button else { return }
        if waiting > 0 {
            button.attributedTitle = NSAttributedString(string: " \(waiting)", attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)])
        } else {
            button.title = ""
        }
        button.toolTip = "\(waiting) need you · \(working) working"
        button.appearsDisabled = sessions.isEmpty
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for which in Hotkeys.shared.conflicts.sorted() {
                let s = which == "switcher" ? Hotkeys.shared.switcher : Hotkeys.shared.search
                menu.addItem(withTitle: "⚠︎ \(s.display) is taken by another app. Change it…", action: #selector(settings), keyEquivalent: "").target = self
            }
            if !Hotkeys.shared.conflicts.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "About Muster", action: #selector(about), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Welcome Tour…", action: #selector(tour), keyEquivalent: "").target = self
            if WhatsNew.shared.available {
                menu.addItem(withTitle: "What's New…", action: #selector(whatsNew), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Usage…", action: #selector(usage), keyEquivalent: "").target = self
            HookSetup.shared.refresh()
            if !HookSetup.shared.pending.isEmpty {
                menu.addItem(withTitle: "Finish approval setup…", action: #selector(settings), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Muster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        let frame = item.button?.window?.frame
        onClick?(frame)
    }

    @objc private func settings() { onSettings?() }
    @objc private func usage() { onUsage?() }
    @objc private func tour() { onTour?() }
    @objc private func whatsNew() { WhatsNew.shared.show() }
    @objc private func checkUpdates() { Updates.check(manual: true) }

    /// After the tour: point at the icon, or explain where Muster went if the
    /// menu bar is too full to show it.
    func showCallout() {
        let visible = item.button?.window.map(Self.onScreen) ?? false
        let keys = Hotkeys.shared
        let title = visible ? "Muster lives here" : "Your menu bar is full"
        let detail = visible ? "\(keys.switcher.display) to switch  ·  \(keys.search.display) to search"
                             : "Muster's icon is hidden. \(keys.search.display) always opens it."
        let panel = callout ?? GlassPanel(cornerRadius: 16, canBecomeKey: false)
        callout = panel
        panel.ignoresMouseEvents = true
        panel.content.subviews.forEach { $0.removeFromSuperview() }
        let top = label(13, .semibold), bottom = label(11.5, .medium, .secondaryLabelColor)
        set(top, title)
        set(bottom, detail)
        [top, bottom].forEach { $0.alignment = .center; panel.content.addSubview($0) }
        let width = max(top.intrinsicContentSize.width, bottom.intrinsicContentSize.width) + 36
        let size = NSSize(width: width, height: 58)
        top.frame = NSRect(x: 0, y: 11, width: width, height: 17)
        bottom.frame = NSRect(x: 0, y: 31, width: width, height: 15)
        let origin: NSPoint
        if visible, let anchor = item.button?.window?.frame {
            let area = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? .zero
            origin = NSPoint(x: min(max(anchor.midX - width / 2, area.minX + 8), area.maxX - width - 8), y: anchor.minY - size.height - 8)
        } else {
            let area = NSScreen.main?.visibleFrame ?? .zero
            origin = NSPoint(x: area.midX - width / 2, y: area.maxY - size.height - 12)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (visible ? 5 : 9)) { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel?.animator().alphaValue = 0 }) { panel?.orderOut(nil) }
        }
    }

    /// Off screen, behind the notch, or pushed out by a menu bar manager.
    private static func onScreen(_ w: NSWindow) -> Bool {
        let f = w.frame
        guard w.occlusionState.contains(.visible), let screen = NSScreen.screens.first(where: { $0.frame.contains(f) }) else { return false }
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return true }
        let x = f.midX - screen.frame.minX
        return x <= left.maxX || x >= right.minX
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Never keep an agent waiting.\nOpen source under the MIT License.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])])
    }
}

/// One notification per event: a session starting to wait on you, or finishing.
/// A usage limit or a lapsed sign-in stops every session at once, so it gets one
/// notification per agent, not one per session.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var last: [String: (Status, Date)] = [:]
    private var seeded = false
    private var stopsTold: Set<String> = []

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
        Store.shared.observe { [weak self] in self?.diff($0) }
        Prompts.shared.onChange = { [weak self] in self?.syncPrompts() }
    }

    /// Asked from the tour or Settings, when the reason is on screen, never at launch.
    static func requestAuthorization(_ done: @escaping () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return done() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async(execute: done)
        }
    }

    static func status(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return done(.notDetermined) }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus) }
        }
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }

    private func diff(_ sessions: [Session]) {
        defer { seeded = true; last = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, ($0.status, $0.since)) }) }
        var stops: [String: Session] = [:]
        for s in sessions where s.status == .blocked {
            guard let f = s.fault else { continue }
            let key = "\(s.agent.rawValue)|\(f.kind)|\(f.resets ?? "")"
            if stops[key] == nil { stops[key] = s }
        }
        // Forget stops that have cleared, so the next one is news again.
        stopsTold.formIntersection(stops.keys)
        guard seeded else { stopsTold = Set(stops.keys); return }
        for (key, s) in stops where !stopsTold.contains(key) {
            stopsTold.insert(key)
            if Settings.notifyNeedsYou { postStop(s) }
        }
        for s in sessions where s.promptID == nil {
            let prev = last[s.id]
            if prev?.0 == s.status && prev?.1 == s.since { continue }
            // While the alert is on it already shows who's waiting; a banner too only doubles it.
            if (s.status == .error || (s.status == .needsYou && !Attention.enabled)) && Settings.notifyNeedsYou && prev?.0 != s.status {
                post(s, s.status == .error ? "hit an error" : "needs you")
            } else if s.status == .done && Settings.notifyDone && (prev?.0 == .working || prev?.0 == .needsYou) {
                post(s, "finished")
            }
        }
    }

    private var questionCategories: [UNNotificationCategory] = []
    private var shownPrompts: Set<UUID> = []

    private func registerCategories() {
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
        let always = UNNotificationAction(identifier: "always", title: "Always Allow", options: [])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let approve = UNNotificationAction(identifier: "allow", title: "Approve", options: [])
        let keep = UNNotificationAction(identifier: "deny", title: "Keep Planning", options: [])
        UNUserNotificationCenter.current().setNotificationCategories(Set([
            UNNotificationCategory(identifier: "session", actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission-always", actions: [allow, always, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plan", actions: [approve, keep], intentIdentifiers: []),
        ] + questionCategories))
    }

    /// Post new prompts with their answers as buttons; withdraw answered ones.
    private func syncPrompts() {
        let current = Set(Prompts.shared.pending.keys)
        let gone = shownPrompts.subtracting(current)
        if !gone.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone.map(\.uuidString)) }
        for id in current.subtracting(shownPrompts) {
            guard let p = Prompts.shared.pending[id], Settings.notifyNeedsYou, !Attention.enabled else { continue }
            let c = UNMutableNotificationContent()
            c.title = "\(p.agent.name) · \(p.headline)"
            c.subtitle = p.remoteHost ?? ""
            c.body = p.detail
            c.sound = .default
            c.userInfo = ["prompt": id.uuidString]
            switch p.kind {
            case .permission(_, _, let always): c.categoryIdentifier = always ? "permission-always" : "permission"
            case .plan: c.categoryIdentifier = "plan"
            case .question(_, let options):
                let cat = "question-" + id.uuidString
                questionCategories.append(UNNotificationCategory(identifier: cat, actions: options.prefix(4).enumerated().map {
                    UNNotificationAction(identifier: "opt\($0.offset)", title: $0.element, options: [])
                }, intentIdentifiers: []))
                registerCategories()
                c.categoryIdentifier = cat
                c.body = p.headline
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: c, trigger: nil))
        }
        shownPrompts = current
    }

    private func postStop(_ s: Session) {
        guard let f = s.fault else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(s.agent.name) is \(f.kind == .limit ? "out of usage" : "signed out")"
        c.body = f.resets.map { "Resets \($0)" } ?? f.message.components(separatedBy: " · ").first ?? ""
        c.categoryIdentifier = "session"
        c.userInfo = ["id": s.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(s.agent.rawValue)-stop-\(s.since.timeIntervalSince1970)",
                                                                     content: c, trigger: nil))
    }

    private func post(_ s: Session, _ verb: String) {
        let c = UNMutableNotificationContent()
        c.title = "\(s.agent.name) \(verb)"
        c.body = s.displayTitle
        c.sound = s.status == .done ? nil : .default
        c.categoryIdentifier = "session"
        c.userInfo = ["id": s.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(s.id)-\(s.since.timeIntervalSince1970)",
                                                                     content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            if let pid = (info["prompt"] as? String).flatMap(UUID.init), let p = Prompts.shared.pending[pid] {
                switch action {
                case "allow": Prompts.shared.answer(p, .allow)
                case "always": Prompts.shared.answer(p, .alwaysAllow)
                case "deny": Prompts.shared.answer(p, .deny)
                case let a where a.hasPrefix("opt"): Prompts.shared.answer(p, .option(Int(a.dropFirst(3)) ?? 0))
                default:
                    if let s = Store.shared.sessions.first(where: { $0.promptID == pid }) { Opener.open(s) }
                }
            } else if let s = Store.shared.sessions.first(where: { $0.id == info["id"] as? String }) {
                Opener.open(s)
            }
            done()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItem!
    private var switcher: Switcher!
    private var deck: Deck!
    let settings = Windows()
    private var notifier: Notifier?
    private var welcome: Welcome!
    private var attention: Attention!

    func deckToggle() { deck.toggle(below: nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        E2E.start()
        if !Store.demo, !E2E.on, Installer.handOffIfRunning() || Installer.offerMove() { NSApp.terminate(nil); return }
        DistributedNotificationCenter.default().addObserver(forName: Installer.reopen, object: nil, queue: .main) { [weak self] _ in
            self?.settings.show()
        }
        Store.shared.start()
        if !Store.demo { Prompts.shared.start() }
        switcher = Switcher()
        deck = Deck()
        status = StatusItem()
        status.onClick = { [weak self] anchor in self?.deck.toggle(below: anchor) }
        status.onSettings = { [weak self] in self?.settings.show() }
        status.onUsage = { [weak self] in self?.settings.showUsage() }
        deck.onSettings = { [weak self] in self?.settings.show() }
        welcome = Welcome(switcher: switcher, deck: deck) { [weak self] in self?.status.showCallout() }
        status.onTour = { [weak self] in self?.welcome.show() }
        Hotkeys.shared.install { [weak self] action in
            guard let self else { return }
            switch action {
            case .next: self.switcher.step(1)
            case .previous: self.switcher.step(-1)
            // Held only while the switcher is open or the alert has details to unfold.
            case .down: if self.switcher.isOpen { self.switcher.step(1) } else { self.attention.peek(true) }
            case .up: if self.switcher.isOpen { self.switcher.step(-1) } else { self.attention.peek(false) }
            case .cancel: self.switcher.cancel()
            case .search: self.deck.toggle(below: nil)
            }
        }
        Agent.allCases.forEach(Agent.load)   // icons decode in the background before the first alert needs one
        attention = Attention()
        Updates.schedule()
        Hotkeys.shared.onAnswer = { [weak self] a in
            guard let self else { return }
            if self.switcher.isOpen { self.switcher.answer(a) }
            else if self.deck.isVisible { self.deck.answer(a) }
            else { self.attention.answer(a) }
        }
        if Bundle.main.bundleIdentifier != nil && !Store.demo && !E2E.on { notifier = Notifier() }
        if Store.demo, CommandLine.arguments.contains("--backdrop") { Demo.showBackdrop() }
        Demo.play(answer: { [weak self] a in self?.attention.answer(a) }, switcher: switcher, deck: deck)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        if !E2E.on && !UserDefaults.standard.bool(forKey: "launched") && (!Store.demo || CommandLine.arguments.contains("--welcome")) {
            welcome.show()
        }
        WhatsNew.shared.showIfUpdated()
    }
}

extension AppDelegate {
    /// muster://search, muster://settings, muster://usage, muster://welcome, muster://whats-new, muster://next (the most
    /// urgent session), muster://open?id=claude:<session id>. For Raycast, Alfred and Shortcuts.
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URLComponents(string: text) else { return }
        switch url.host {
        case "search": deckToggle()
        case "settings": settings.show()
        case "usage": settings.showUsage()
        case "welcome": welcome.show()
        case "whats-new": WhatsNew.shared.show()
        case "next": if let s = Store.shared.sessions.first { Opener.open(s) }
        case "open":
            let id = url.queryItems?.first { $0.name == "id" }?.value
            if let s = Store.shared.sessions.first(where: { $0.id == id }) { Opener.open(s) }
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
