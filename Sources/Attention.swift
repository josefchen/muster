import AppKit

/// A glass alert at the top of the screen while an agent waits on you. It never
/// takes focus, answers with the same keys as the switcher, and stays until the
/// wait ends or you dismiss it. Works whatever the notification settings, Focus
/// mode or menu bar layout.
final class Attention {
    static let width: CGFloat = 540
    static let changed = Notification.Name("dev.muster.app.attention")
    private static let inset: CGFloat = 6

    private let panel = GlassPanel(cornerRadius: 22, canBecomeKey: false)
    private let surface = AlertSurface()
    private let row = SessionRow(frame: .zero)
    private let tint = NSView()
    private let more = label(11, .medium, .tertiaryLabelColor)
    private var current: Session?
    private var dismissed: Set<String> = []
    private var keysOn = false
    private var shown = false

    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "mute.alert") && (!Store.demo || CommandLine.arguments.contains("--attention")) }
        set { UserDefaults.standard.set(!newValue, forKey: "mute.alert") }
    }

    init() {
        more.alignment = .center
        surface.frame = panel.content.bounds
        surface.autoresizingMask = [.width, .height]
        surface.onClick = { [weak self] in self?.open() }
        surface.onDismiss = { [weak self] in self?.dismiss() }
        tint.wantsLayer = true
        tint.layer?.cornerRadius = 16
        tint.layer?.borderWidth = 1
        tint.layer?.backgroundColor = Status.needsYou.colour.withAlphaComponent(0.14).cgColor
        tint.layer?.borderColor = Status.needsYou.colour.withAlphaComponent(0.45).cgColor
        [tint, row, more].forEach(surface.addSubview)
        panel.content.addSubview(surface)
        Store.shared.observe { [weak self] _ in self?.update() }
        NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in self?.update() }
    }

    func answer(_ a: Answer) {
        guard let id = current?.promptID, let p = Prompts.shared.pending[id] else { return }
        Prompts.shared.answer(p, a)
    }

    private func key(_ s: Session) -> String { "\(s.id)|\(s.since.timeIntervalSince1970)|\(s.promptID?.uuidString ?? "")" }

    private func update() {
        let waiting = Store.shared.sessions.filter { $0.status == .needsYou }
        dismissed.formIntersection(waiting.map(key))
        let pending = waiting.filter { !dismissed.contains(key($0)) }
        guard Self.enabled, let first = pending.first else { return hide() }
        current = first
        row.show(first, now: Date())
        let extra = pending.count - 1
        set(more, extra > 0 ? "\(extra) more waiting   ·   \(Hotkeys.shared.switcher.display) to see all" : "")
        more.isHidden = extra == 0
        setKeys(first.promptID != nil)
        show(height: SessionRow.height + Self.inset * 2 + (extra > 0 ? 20 : 0))
    }

    private func show(height: CGFloat) {
        let size = NSSize(width: Self.width, height: height)
        row.frame = NSRect(x: Self.inset, y: Self.inset, width: size.width - Self.inset * 2, height: SessionRow.height)
        tint.frame = row.frame
        more.frame = NSRect(x: 0, y: Self.inset + SessionRow.height + 1, width: size.width, height: 14)
        surface.closeFrame = NSRect(x: 4, y: 4, width: 18, height: 18)
        if shown {
            var f = panel.frame
            f.origin.y += f.height - height
            f.size = size
            panel.setFrame(f, display: true)
            panel.invalidateShadow()
            return
        }
        shown = true
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
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
        setKeys(false)
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

    private func setKeys(_ on: Bool) {
        guard on != keysOn else { return }
        keysOn = on
        Hotkeys.shared.answerKeys(on, owner: "attention")
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
