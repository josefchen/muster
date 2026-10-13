import AppKit

/// The switcher shortcut (⌥Tab by default), held: a glass list of sessions, most
/// urgent first. Tab / ⇧Tab or the arrows move, letting go opens, Esc cancels. A quick tap opens the most urgent
/// session without showing the panel at all, like ⌘Tab's quick switch.
final class Switcher {
    static let width: CGFloat = 600
    static let showDelay: TimeInterval = 0.12
    static let recentLimit = 5

    private let panel = GlassPanel(cornerRadius: 26, canBecomeKey: true)
    private let list = SessionList(frame: .zero)
    private let hint = label(11, .medium, .tertiaryLabelColor)
    private let empty = label(15, .medium, .secondaryLabelColor)
    private var snapshot: [Session] = []
    private var active = false
    private var showTimer: Timer?
    private var releaseWatch: Timer?
    private var localMouse: Any?
    private var globalMouse: Any?
    private var pointing = false

    /// The tour's practice run: letting go or clicking closes instead of opening.
    var practice = false
    var onShow: (() -> Void)?
    var onPractice: (() -> Void)?

    init() {
        hint.alignment = .center
        hint.stringValue = Self.hintText
        empty.alignment = .center
        empty.stringValue = "No agents running"
        panel.acceptsMouseMovedEvents = true
        panel.identifier = NSUserInterfaceItemIdentifier("muster.switcher")
        [list, hint, empty].forEach(panel.content.addSubview)
        list.onHover = { [weak self] i in self?.highlight(i) }
        list.onClick = { [weak self] i in self?.choose(i) }
        list.updateTrackingAreas()
    }

    static var hintText: String {
        let s = Hotkeys.shared.switcher
        return "\(s.key) next   ·   ⇧\(s.key) back   ·   click or release to open   ·   Esc cancel"
    }

    func step(_ delta: Int) {
        if !active { begin(); return }
        guard !snapshot.isEmpty else { return }
        list.select((list.selected + delta + snapshot.count) % snapshot.count, animated: panel.isVisible)
    }

    var isOpen: Bool { active }

    func cancel() { end() }

    /// Answer the selected session's prompt and close, without switching to it.
    func answer(_ a: Answer) {
        guard active, snapshot.indices.contains(list.selected),
              let id = snapshot[list.selected].promptID, let p = Prompts.shared.pending[id] else { return }
        Prompts.shared.answer(p, a)
        end()
    }

    private func begin() {
        active = true
        Hotkeys.shared.hold(.all, owner: "switcher")
        hint.stringValue = Self.hintText
        snapshot = Self.pick(Store.shared.sessions)
        if practice && snapshot.isEmpty { snapshot = Self.pick(Session.samples) }
        layout()
        watchRelease()
        watchPointer()
        showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDelay, repeats: false) { [weak self] _ in self?.reveal() }
    }

    /// Everything that needs you or is working, then the latest few that finished.
    static func pick(_ sessions: [Session]) -> [Session] {
        let live = sessions.filter { $0.status.section != .recent }
        let recent = sessions.filter { $0.status.section == .recent }.prefix(recentLimit)
        return Array(live + recent)
    }

    private func layout() {
        let screen = Store.demo ? NSScreen.screens.first : NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let listHeight = snapshot.isEmpty ? 64 : min(SessionList.height(for: snapshot), area.height * 0.7)
        let size = NSSize(width: Self.width, height: listHeight + 34)
        // Top edge stays put as the list grows or shrinks, so the panel never jumps.
        let top = area.maxY - area.height * 0.18
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: false)
        list.frame = NSRect(x: 0, y: 0, width: size.width, height: listHeight)
        hint.frame = NSRect(x: 0, y: size.height - 26, width: size.width, height: 14)
        empty.frame = NSRect(x: 0, y: 22, width: size.width, height: 20)
        empty.isHidden = !snapshot.isEmpty
        list.isHidden = snapshot.isEmpty
        list.show(snapshot, selected: 0)
    }

    private func reveal() {
        guard active else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        onShow?()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func watchRelease() {
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            let held = E2E.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let self, !held.isSuperset(of: Hotkeys.shared.switcher.flags.subtracting(.shift)) else { return }
            let chosen = self.snapshot.indices.contains(self.list.selected) ? self.snapshot[self.list.selected] : nil
            self.end()
            if self.practice { self.onPractice?() } else if let chosen { Opener.open(chosen) }
        }
    }

    /// The panel is non-activating, so a click can land in the app behind it.
    /// The global monitor catches that case. Events this app does receive come
    /// through the list, and the two never both fire for one click.
    private func watchPointer() {
        guard E2E.showsUI else { return }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved]) { [weak self] event in
            self?.pointer(event, click: event.type == .leftMouseDown)
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved]) { [weak self] event in
            self?.pointer(event, click: event.type == .leftMouseDown)
        }
    }

    private func pointer(_ event: NSEvent, click: Bool) {
        guard active, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard panel.frame.contains(mouse) else {
            if pointing { NSCursor.arrow.set(); pointing = false }
            return
        }
        let inList = list.convert(panel.convertPoint(fromScreen: mouse), from: nil)
        guard let i = list.rowIndex(at: inList) else {
            if pointing { NSCursor.arrow.set(); pointing = false }
            return
        }
        if click { choose(i) } else { highlight(i) }
    }

    private func highlight(_ i: Int) {
        guard active, snapshot.indices.contains(i) else { return }
        if !pointing { NSCursor.pointingHand.set(); pointing = true }
        guard i != list.selected else { return }
        list.select(i, animated: true)
    }

    private func choose(_ i: Int) {
        guard active, snapshot.indices.contains(i) else { return }
        let chosen = snapshot[i]
        end()
        if practice { onPractice?() } else { Opener.open(chosen) }
    }

    private func end() {
        active = false
        Hotkeys.shared.hold(nil, owner: "switcher")
        showTimer?.invalidate()
        releaseWatch?.invalidate()
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        showTimer = nil
        releaseWatch = nil
        localMouse = nil
        globalMouse = nil
        if pointing { NSCursor.arrow.set(); pointing = false }
        panel.orderOut(nil)
    }
}
