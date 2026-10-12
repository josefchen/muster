import AppKit

/// The switcher shortcut (⌥Tab by default), held: a glass list of sessions, most
/// urgent first. Tab / ⇧Tab or the arrows move, letting go opens, Esc cancels. A quick tap opens the most urgent
/// session without showing the panel at all, like ⌘Tab's quick switch.
final class Switcher {
    static let width: CGFloat = 600
    static let showDelay: TimeInterval = 0.12
    static let recentLimit = 5

    private let panel = GlassPanel(cornerRadius: 26, canBecomeKey: false)
    private let list = SessionList(frame: .zero)
    private let hint = label(11, .medium, .tertiaryLabelColor)
    private let empty = label(15, .medium, .secondaryLabelColor)
    private var snapshot: [Session] = []
    private var active = false
    private var showTimer: Timer?
    private var releaseWatch: Timer?

    init() {
        hint.alignment = .center
        hint.stringValue = Self.hintText
        empty.alignment = .center
        empty.stringValue = "No agents running"
        [list, hint, empty].forEach(panel.content.addSubview)
    }

    static var hintText: String {
        let s = Hotkeys.shared.switcher
        return "\(s.key) next   ·   ⇧\(s.key) back   ·   release \(s.symbols.replacingOccurrences(of: "⇧", with: "")) to open   ·   Esc cancel"
    }

    func step(_ delta: Int) {
        if !active { begin(); return }
        guard !snapshot.isEmpty else { return }
        list.select((list.selected + delta + snapshot.count) % snapshot.count, animated: panel.isVisible)
    }

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
        Hotkeys.shared.answerKeys(true)
        hint.stringValue = Self.hintText
        snapshot = Self.pick(Store.shared.sessions)
        layout()
        watchRelease()
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
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func watchRelease() {
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            let held = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let self, !held.isSuperset(of: Hotkeys.shared.switcher.flags.subtracting(.shift)) else { return }
            let chosen = self.snapshot.indices.contains(self.list.selected) ? self.snapshot[self.list.selected] : nil
            self.end()
            if let chosen { Opener.open(chosen) }
        }
    }

    private func end() {
        active = false
        Hotkeys.shared.answerKeys(false)
        showTimer?.invalidate()
        releaseWatch?.invalidate()
        showTimer = nil
        releaseWatch = nil
        panel.orderOut(nil)
    }
}
