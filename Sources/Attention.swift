import AppKit

/// A glass alert at the top of the screen while an agent waits on you. It never
/// takes focus, answers with the same keys as the switcher, and stays until the
/// wait ends or you dismiss it. Works whatever the notification settings, Focus
/// mode or menu bar layout. ⌥↓ unfolds what the agent sent in full, so you can
/// decide without switching; a click opens the session itself.
final class Attention {
    static let width: CGFloat = 540
    static let changed = Notification.Name("dev.muster.app.attention")
    /// Posted by e2e runs, with an NSNumber: true unfolds the details, false folds them.
    static let peekRequest = Notification.Name("dev.muster.app.attention.peek")
    private static let inset: CGFloat = 6
    private static let textX: CGFloat = 58            // where the row's title starts
    private static var detailWidth: CGFloat { width - inset - textX - 22 }

    private let panel = GlassPanel(cornerRadius: 22, canBecomeKey: false)
    private let surface = AlertSurface()
    private let row = SessionRow(frame: .zero)
    private let more = label(11, .medium, .tertiaryLabelColor)
    private let details = NSTextField(wrappingLabelWithString: "")
    private var expandedFor: String?                 // the waiting prompt whose details are open
    private var current: Session?
    private var dismissed: Set<String> = []
    private var shown = false
    private var typingWatch: Timer?
    private var typing = false
    private var shownHints: ([KeyHint], Bool)?
    private var answeringChecked: [Agent: (Date, Bool)] = [:]

    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "mute.alert") && (!Store.demo || CommandLine.arguments.contains("--attention")) }
        set { UserDefaults.standard.set(!newValue, forKey: "mute.alert") }
    }

    init() {
        more.alignment = .center
        more.identifier = NSUserInterfaceItemIdentifier("muster.keys")
        panel.identifier = NSUserInterfaceItemIdentifier("muster.alert")
        surface.frame = panel.content.bounds
        surface.autoresizingMask = [.width, .height]
        surface.onClick = { [weak self] in self?.open() }
        surface.onDismiss = { [weak self] in self?.dismiss() }
        surface.onAppearance = { [weak self] in self?.update() }
        // One surface, warmed by the colour of what it's for, rather than a card inside a card.
        // Only Liquid Glass takes a tint well; over the older material orange turns brown.
        panel.tint(Status.needsYou.colour.withAlphaComponent(0.16))
        details.identifier = NSUserInterfaceItemIdentifier("muster.details")
        details.isSelectable = false
        details.maximumNumberOfLines = 18
        details.cell?.truncatesLastVisibleLine = true
        details.isHidden = true
        [row, details, more].forEach(surface.addSubview)
        panel.content.addSubview(surface)
        Store.shared.observe { [weak self] _ in self?.update() }
        NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in self?.update() }
        NotificationCenter.default.addObserver(forName: Self.peekRequest, object: nil, queue: .main) { [weak self] n in
            self?.peek((n.object as? NSNumber)?.boolValue ?? true)
        }
    }

    /// ⌥↓ unfolds what the agent sent, ⌥↑ folds it away. False when the alert has nothing
    /// to unfold or is already that way.
    @discardableResult
    func peek(_ open: Bool) -> Bool {
        guard shown, let s = current, s.promptID != nil, open != (expandedFor == key(s)) else { return false }
        expandedFor = open ? key(s) : nil
        update()
        return true
    }

    func answer(_ a: Answer) {
        guard let id = current?.promptID, let p = Prompts.shared.pending[id] else { return }
        Prompts.shared.answer(p, a)
    }

    private func key(_ s: Session) -> String { "\(s.id)|\(s.since.timeIntervalSince1970)|\(s.promptID?.uuidString ?? "")|\(s.asking ?? "")" }

    private func update() {
        let waiting = Store.shared.sessions.filter { $0.status == .needsYou }
        dismissed.formIntersection(waiting.map(key))
        let pending = waiting.filter { !dismissed.contains(key($0)) }
        guard Self.enabled, let first = pending.first else { return hide() }
        current = first
        let prompt = first.promptID.flatMap { Prompts.shared.pending[$0] }
        if expandedFor != nil, expandedFor != key(first) { expandedFor = nil }   // a new prompt starts folded
        let open = prompt != nil && expandedFor == key(first)
        row.show(first, now: Date(), unfolded: open, trailing: false)
        var hints = Self.hints(prompt, open: open, more: pending.count - 1, offerAnswering: first.remoteHost == nil && prompt == nil && first.asking == nil && !answering(first.agent))
        if first.remoteHost == nil, prompt == nil, first.asking == nil, first.agent != .cursor, answering(first.agent) {
            hints.append(KeyHint([], "Approval missing here? Check the connection in Settings"))
        }
        if let host = first.remoteHost { hints.append(KeyHint([], first.remoteOffline ? "\(host) offline · Last known request" : "Answer on \(host)")) }
        let dark = surface.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if hints != shownHints?.0 || dark != shownHints?.1 {
            shownHints = (hints, dark)
            more.attributedStringValue = keyHints(hints, appearance: surface.effectiveAppearance)
            more.setAccessibilityLabel(hints.map { ($0.keys.joined() + " " + $0.action).trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
        }
        var detailHeight: CGFloat = 0
        if open, let prompt {
            details.attributedStringValue = Self.details(prompt)
            detailHeight = min(320, ceil(details.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.detailWidth, height: 10_000)).height ?? 0))
        }
        details.isHidden = detailHeight == 0
        surface.setAccessibilityValue(details.isHidden ? nil : details.stringValue)
        setKeys(prompt)
        show(height: SessionRow.height + Self.inset * 2 + (detailHeight > 0 ? detailHeight + 14 : 0) + 26, details: detailHeight)
    }

    /// Every alert says which keys act on it, so nobody has to know them beforehand.
    private static func hints(_ p: Prompt?, open: Bool, more extra: Int, offerAnswering: Bool) -> [KeyHint] {
        let m = Hotkeys.shared.switcher.symbols.replacingOccurrences(of: "⇧", with: "")
        let fold = KeyHint([m + (open ? "↑" : "↓")], open ? "Less" : "Details")
        var hints: [KeyHint]
        switch p?.kind {
        case .permission?: hints = [KeyHint([m + "↩"], "Allow"), KeyHint([m + "⌫"], "Deny"), fold]
        case .question(_, let options)?:
            let last = min(9, options.count)
            hints = [KeyHint(last > 1 ? [m + "1", "–", m + "\(last)"] : [m + "1"], "Choose"), KeyHint([m + (open ? "↑" : "↓")], open ? "Less" : "Options")]
        case .plan?: hints = [KeyHint([m + "↩"], "Approve"), KeyHint([m + "⌫"], "Keep planning"), KeyHint([m + (open ? "↑" : "↓")], open ? "Less" : "Plan")]
        case nil:
            hints = [KeyHint([Hotkeys.shared.switcher.display], "Go to it")]
            if offerAnswering { hints.append(KeyHint([], "Reply from here: turn it on in Settings")) }
        }
        if extra > 0 { hints.append(KeyHint(p == nil ? [] : [Hotkeys.shared.switcher.display], "\(extra) more waiting")) }
        return hints
    }

    /// Why the agent asks, exactly what it would do, the choices with their notes, and where.
    private static func details(_ p: Prompt) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 1.5
        para.paragraphSpacing = 5
        func line(_ parts: [(String, NSFont, NSColor)]) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            for (text, font, colour) in parts {
                out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: para]))
            }
        }
        let c = p.context
        if !c.reason.isEmpty { line([(c.reason, .systemFont(ofSize: 12.5, weight: .medium), .labelColor)]) }
        // The row already shows a short, one-line command whole; repeat only what it has to cut.
        var shownInRow = false
        if case .permission(_, let summary, _) = p.kind { shownInRow = summary == c.body && c.body.count <= 46 && !c.body.contains("\n") }
        if !c.body.isEmpty, !shownInRow {
            let lines = c.body.split(separator: "\n", omittingEmptySubsequences: false)
            let text = lines.prefix(12).joined(separator: "\n") + (lines.count > 12 ? "\n…" : "")
            line([(text, c.code ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12), .secondaryLabelColor)])
        }
        for (i, choice) in c.choices.enumerated() {
            line([("\(i + 1)   ", .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .tertiaryLabelColor),
                  (choice.label, .systemFont(ofSize: 12.5, weight: .medium), .labelColor),
                  (choice.note.isEmpty ? "" : "   " + choice.note, .systemFont(ofSize: 12), .secondaryLabelColor)])
        }
        if !p.project.isEmpty {
            let folder = p.project.hasPrefix(home) ? "~" + p.project.dropFirst(home.count) : p.project
            line([("in " + folder, .systemFont(ofSize: 11), .tertiaryLabelColor)])
        }
        return out
    }

    private func show(height: CGFloat, details detailHeight: CGFloat) {
        let size = NSSize(width: Self.width, height: height)
        row.frame = NSRect(x: Self.inset, y: Self.inset, width: size.width - Self.inset * 2, height: SessionRow.height)
        details.frame = NSRect(x: Self.inset + Self.textX, y: Self.inset + SessionRow.height + 2, width: Self.detailWidth, height: detailHeight)
        let body = detailHeight > 0 ? row.frame.union(details.frame.insetBy(dx: 0, dy: -8)) : row.frame
        more.frame = NSRect(x: 0, y: body.maxY + 4, width: size.width, height: 19)
        surface.closeFrame = NSRect(x: 4, y: 4, width: 18, height: 18)
        if shown {
            var f = panel.frame
            f.origin.y += f.height - height
            f.size = size
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(f, display: true)
            }
            panel.invalidateShadow()
            return
        }
        shown = true
        let screen = Store.demo ? NSScreen.screens.first : NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let final = NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 8, width: size.width, height: size.height)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(still ? final : final.offsetBy(dx: 0, dy: 10), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = still ? 0.15 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    private func hide() {
        current = nil
        setKeys(nil)
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }) { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Whether Muster can answer this agent's prompts. Cursor never; Claude Code and Codex once
    /// their hook is on. Read from their settings at most every few seconds.
    private func answering(_ agent: Agent) -> Bool {
        guard agent != .cursor else { return true }   // nothing to turn on, so nothing to offer
        if let (at, on) = answeringChecked[agent], Date().timeIntervalSince(at) < 5 { return on }
        let on = HookInstaller.isInstalled(agent)
        answeringChecked[agent] = (Date(), on)
        return on
    }

    /// The prompt's keys, held while it shows, except while you type elsewhere: then ⌥↩ for a
    /// newline or ⌥⌫ to delete a word reaches the app you're in instead of answering.
    private func setKeys(_ prompt: Prompt?) {
        if prompt == nil { typingWatch?.invalidate(); typingWatch = nil; typing = false }
        else if typingWatch == nil {
            typing = Self.typingNow()
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self, Self.typingNow() != self.typing else { return }
                self.typing.toggle()
                self.update()
            }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            typingWatch = t
        }
        Hotkeys.shared.hold(typing ? nil : prompt.map(Self.keys(for:)), owner: "attention")
        more.alphaValue = typing ? 0.4 : 1
        more.toolTip = typing ? "Paused while you type" : nil
    }

    static func keys(for p: Prompt) -> Hotkeys.PanelKeys {
        switch p.kind {
        case .permission(_, _, let always): return Hotkeys.PanelKeys(arrows: true, confirm: true, always: always, deny: true)
        case .question(_, let options): return Hotkeys.PanelKeys(arrows: true, digits: min(9, options.count))
        case .plan: return Hotkeys.PanelKeys(arrows: true, confirm: true, deny: true)
        }
    }

    /// A key pressed in the last second, other than one of Muster's own.
    private static func typingNow() -> Bool {
        if let forced = E2E.typing { return forced }
        let since = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return since < 1 && Date().timeIntervalSince(Hotkeys.shared.lastPress) > since + 0.1
    }

    private func open() {
        guard let s = current else { return }
        dismissed.insert(key(s))
        update()
        Opener.open(s)
    }

    private func dismiss() {
        guard let s = current else { return }
        dismissed.insert(key(s))
        update()
    }
}

/// Takes the first click without activating Muster. Hovering shows a close
/// button in the corner, like a notification.
private final class AlertSurface: Flipped {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onAppearance: (() -> Void)?
    var closeFrame: NSRect = .zero { didSet { close.frame = closeFrame } }
    private let close = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        close.contentTintColor = .secondaryLabelColor
        close.isHidden = true
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open the waiting session")
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The keycaps are drawn for one appearance; redraw them for the other.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearance?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { close.isHidden = false; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { close.isHidden = true; NSCursor.arrow.set() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeFrame.insetBy(dx: -4, dy: -4).contains(p) { onDismiss?() } else { onClick?() }
    }
}
