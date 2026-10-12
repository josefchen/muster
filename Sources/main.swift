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
    static var notifyDone: Bool {
        get { !d.bool(forKey: "mute.done") }
        set { d.set(!newValue, forKey: "mute.done") }
    }
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}

/// Menu bar: one glyph, plus a count while sessions need you. Click for the deck;
/// right-click for settings and quit.
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onClick: ((NSRect?) -> Void)?
    var onSettings: (() -> Void)?

    override init() {
        super.init()
        item.button?.image = Self.glyph()
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Every agent, one glance.\nOpen source under the MIT License.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])])
    }
}

/// One notification per event: a session starting to wait on you, or finishing.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var last: [String: (Status, Date)] = [:]
    private var seeded = false

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { FileHandle.standardError.write(Data("muster: notifications unavailable: \(error.localizedDescription)\n".utf8)) }
            else if !granted { FileHandle.standardError.write(Data("muster: notifications declined\n".utf8)) }
        }
        registerCategories()
        Store.shared.observe { [weak self] in self?.diff($0) }
        Prompts.shared.onChange = { [weak self] in self?.syncPrompts() }
    }

    private func diff(_ sessions: [Session]) {
        defer { seeded = true; last = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, ($0.status, $0.since)) }) }
        guard seeded else { return }
        for s in sessions where s.promptID == nil {
            let prev = last[s.id]
            if prev?.0 == s.status && prev?.1 == s.since { continue }
            if (s.status == .needsYou || s.status == .error) && Settings.notifyNeedsYou && prev?.0 != s.status {
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
            guard let p = Prompts.shared.pending[id], Settings.notifyNeedsYou else { continue }
            let c = UNMutableNotificationContent()
            c.title = "\(p.agent.name) · \(p.headline)"
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

    func deckToggle() { deck.toggle(below: nil) }

    func applicationDidFinishLaunching(_ n: Notification) {
        Store.shared.start()
        if !Store.demo { Prompts.shared.start() }
        switcher = Switcher()
        deck = Deck()
        status = StatusItem()
        status.onClick = { [weak self] anchor in self?.deck.toggle(below: anchor) }
        status.onSettings = { [weak self] in self?.settings.show() }
        deck.onSettings = { [weak self] in self?.settings.show() }
        Hotkeys.shared.install { [weak self] action in
            guard let self else { return }
            switch action {
            case .next, .down: self.switcher.step(1)
            case .previous, .up: self.switcher.step(-1)
            case .cancel: self.switcher.cancel()
            case .search: self.deck.toggle(below: nil)
            }
        }
        Hotkeys.shared.onAnswer = { [weak self] a in self?.switcher.answer(a) }
        if Bundle.main.bundleIdentifier != nil && !Store.demo { notifier = Notifier() }
        if Store.demo, CommandLine.arguments.contains("--backdrop") { Demo.showBackdrop() }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        if !UserDefaults.standard.bool(forKey: "launched") && !Store.demo {
            UserDefaults.standard.set(true, forKey: "launched")
            Settings.launchAtLogin = true
            settings.welcome()
        }
    }
}

extension AppDelegate {
    /// muster://search, muster://settings, muster://next (the most urgent session),
    /// muster://open?id=claude:<session id>. For Raycast, Alfred and Shortcuts.
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URLComponents(string: text) else { return }
        switch url.host {
        case "search": deckToggle()
        case "settings": settings.show()
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
