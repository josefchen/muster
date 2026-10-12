import AppKit

/// Every recent session, searchable. Opens from the menu bar or ⌃⌥Space; type to
/// filter, ↑↓ to move, Return to open, ⌘1–9 to jump, Esc or clicking away closes.
final class Deck: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let width: CGFloat = 640
    static let maxListHeight: CGFloat = 460

    private let panel = DeckPanel(cornerRadius: 26, canBecomeKey: true)
    private let search = NSTextField()
    private let filter = NSSegmentedControl(labels: ["All", "Claude", "Codex", "Cursor"], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let scroll = NSScrollView()
    private let list = SessionList(frame: .zero)
    private let empty = label(14, .medium, .secondaryLabelColor)
    private let emptyIcon = NSImageView()
    private let footer = label(11, .medium, .tertiaryLabelColor)
    private let gear = NSButton()
    private var shown: [Session] = []
    private var selectedID: String?

    var onSettings: (() -> Void)?
    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] e in self?.keyEquivalent(e) ?? false }

        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 20, weight: .regular)
        search.placeholderString = "Search agents"
        search.delegate = self

        filter.selectedSegment = 0
        filter.segmentStyle = .automatic
        filter.controlSize = .small
        filter.target = self
        filter.action = #selector(refilter)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.contentView.drawsBackground = false
        list.onClick = { [weak self] i in self?.open(i) }
        list.onHover = { [weak self] i in
            guard let self, self.shown.indices.contains(i) else { return }
            self.list.select(i, animated: true)
            self.selectedID = self.shown[i].id
        }

        empty.alignment = .center
        emptyIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .light))
        emptyIcon.contentTintColor = .tertiaryLabelColor
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        gear.isBordered = false
        gear.contentTintColor = .tertiaryLabelColor
        gear.target = self
        gear.action = #selector(settings)

        [search, filter, scroll, emptyIcon, empty, footer, gear].forEach(panel.content.addSubview)
        Store.shared.observe { [weak self] _ in
            if self?.panel.isVisible == true { self?.refilter() }
        }
    }

    private var keyMonitor: Any?

    func toggle(below anchor: NSRect?) {
        if panel.isVisible { hide(); return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.answerKey(e) == true ? nil : e
        }
        search.stringValue = ""
        filter.selectedSegment = 0
        selectedID = nil
        refilter()
        position(below: anchor)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        panel.makeFirstResponder(search)
        onShow?()
    }

    func hide() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onHide?()
    }

    /// ⌥Return allows, ⌥⇧Return always allows, ⌥Delete denies, ⌥1–9 answers, for the
    /// selected row's prompt (with the switcher's modifiers, ⌥ by default).
    private func answerKey(_ e: NSEvent) -> Bool {
        let held = e.modifierFlags.intersection([.control, .option, .command])
        guard held == Hotkeys.shared.switcher.flags.intersection([.control, .option, .command]), !held.isEmpty,
              shown.indices.contains(list.selected), let id = shown[list.selected].promptID,
              let p = Prompts.shared.pending[id] else { return false }
        let answer: Answer
        switch Int(e.keyCode) {
        case 36: answer = e.modifierFlags.contains(.shift) ? .alwaysAllow : .allow
        case 51: answer = .deny
        default:
            guard let n = Int(e.charactersIgnoringModifiers ?? ""), (1...9).contains(n) else { return false }
            answer = .option(n - 1)
        }
        Prompts.shared.answer(p, answer)
        return true
    }

    // MARK: data

    @objc private func refilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let agent: Agent? = filter.selectedSegment > 0 ? Agent.allCases[filter.selectedSegment - 1] : nil
        shown = Store.shared.sessions.filter { s in
            (agent == nil || s.agent == agent) && (query.isEmpty
                || s.displayTitle.lowercased().contains(query) || s.project.lowercased().contains(query)
                || s.agent.name.lowercased().contains(query))
        }
        let index = shown.firstIndex { $0.id == selectedID } ?? 0
        layout()
        list.show(shown, selected: index)
        selectedID = shown.indices.contains(index) ? shown[index].id : nil
        let total = shown.reduce(0) { $0 + $1.tokens }
        let cost = shown.compactMap(\.cost).reduce(0, +)
        var parts = ["\(shown.count) session\(shown.count == 1 ? "" : "s")"]
        if total > 0 { parts.append("\(compact(total)) tokens") }
        if cost > 0 { parts.append("≈ \(money(cost)) at API rates") }
        set(footer, parts.joined(separator: "   ·   "))
        footer.toolTip = "What these sessions would cost on the public APIs (prices from \(Pricing.retrieved)). Not your subscription bill."
    }

    private func layout() {
        let listHeight = shown.isEmpty ? 120 : min(SessionList.height(for: shown), Self.maxListHeight)
        let top: CGFloat = 96, bottom: CGFloat = 38
        let size = NSSize(width: Self.width, height: top + listHeight + bottom)
        if panel.frame.size != size {
            var f = panel.frame
            f.origin.y += f.height - size.height
            f.size = size
            panel.setFrame(f, display: true)
            panel.invalidateShadow()
        }
        search.frame = NSRect(x: 24, y: 22, width: size.width - 48, height: 28)
        filter.frame = NSRect(x: 22, y: 60, width: 300, height: 24)
        scroll.frame = NSRect(x: 0, y: top, width: size.width, height: listHeight)
        list.frame = NSRect(x: 0, y: 0, width: size.width, height: max(listHeight, SessionList.height(for: shown)))
        emptyIcon.frame = NSRect(x: (size.width - 40) / 2, y: top + 22, width: 40, height: 40)
        empty.frame = NSRect(x: 0, y: top + 72, width: size.width, height: 20)
        empty.isHidden = !shown.isEmpty
        emptyIcon.isHidden = !shown.isEmpty
        set(empty, Store.shared.sessions.isEmpty ? "All quiet. No agents in the last 3 hours." : "No sessions match")
        footer.frame = NSRect(x: 24, y: size.height - 26, width: size.width - 80, height: 14)
        gear.frame = NSRect(x: size.width - 40, y: size.height - 31, width: 20, height: 20)
    }

    private func position(below anchor: NSRect?) {
        let screen = Store.demo ? NSScreen.screens.first : NSScreen.screens.first { anchor.map($0.frame.intersects) ?? false } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        let size = panel.frame.size
        var x = area.midX - size.width / 2
        var y = area.maxY - size.height - area.height * 0.12
        if let a = anchor {
            x = min(max(a.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
            y = a.minY - size.height - 6
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: actions

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let i = max(0, min(list.selected + delta, shown.count - 1))
        list.select(i, animated: true)
        selectedID = shown[i].id
        if let f = list.rowFrame(i) { list.scrollToVisible(f.insetBy(dx: 0, dy: -SessionList.headerHeight)) }
    }

    private func open(_ index: Int) {
        guard shown.indices.contains(index) else { return }
        let s = shown[index]
        hide()
        Opener.open(s)
    }

    @objc private func settings() {
        hide()
        onSettings?()
    }

    private func keyEquivalent(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) else { return false }
        open(n - 1)
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        selectedID = nil
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): open(list.selected)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}

final class DeckPanel: GlassPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }
}
