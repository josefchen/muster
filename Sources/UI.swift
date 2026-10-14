import AppKit

// Shared pieces for the switcher and the deck: a glass panel built once and
// reused, a session row that updates in place, and a list that recycles rows.
// Nothing is rebuilt per update; that is what keeps memory flat.

class Flipped: NSView {
    override var isFlipped: Bool { true }
}

func label(_ size: CGFloat, _ weight: NSFont.Weight = .regular, _ colour: NSColor = .labelColor) -> NSTextField {
    let f = NSTextField(labelWithString: "")
    f.font = .systemFont(ofSize: size, weight: weight)
    f.textColor = colour
    f.lineBreakMode = .byTruncatingTail
    f.maximumNumberOfLines = 1
    return f
}

func set(_ field: NSTextField, _ text: String) {
    if field.stringValue != text { field.stringValue = text }
}

/// Keys and what they do, for a hint line: `KeyHint(["⌥↩"], "Allow")`. A key of "–" reads as a range.
struct KeyHint: Equatable {
    let keys: [String]
    let action: String
    init(_ keys: [String], _ action: String) { self.keys = keys; self.action = action }
}

/// The keys drawn as keycaps, each followed by its action, the way a Mac menu shows shortcuts.
func keyHints(_ hints: [KeyHint], size: CGFloat = 11, appearance: NSAppearance) -> NSAttributedString {
    let font = NSFont.systemFont(ofSize: size, weight: .medium)
    let text: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
    let out = NSMutableAttributedString()
    for (i, hint) in hints.enumerated() {
        if i > 0 { out.append(NSAttributedString(string: "      ", attributes: text)) }
        for key in hint.keys {
            if key == "–" { out.append(NSAttributedString(string: " – ", attributes: text)); continue }
            let cap = Keycap.image(key, font: font, appearance: appearance)
            let a = NSTextAttachment()
            a.image = cap
            a.bounds = CGRect(x: 0, y: ((font.capHeight - cap.size.height) / 2).rounded(), width: cap.size.width, height: cap.size.height)
            out.append(NSAttributedString(attachment: a))
        }
        out.append(NSAttributedString(string: (hint.keys.isEmpty ? "" : " ") + hint.action, attributes: text))
    }
    let centred = NSMutableParagraphStyle()
    centred.alignment = .center
    out.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: out.length))
    return out
}

private enum Keycap {
    private static var cache: [String: NSImage] = [:]

    static func image(_ key: String, font: NSFont, appearance: NSAppearance) -> NSImage {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let id = "\(key)|\(font.pointSize)|\(dark)"
        if let hit = cache[id] { return hit }
        let glyphs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: dark ? 1 : 0, alpha: dark ? 0.78 : 0.68)]
        let t = (key as NSString).size(withAttributes: glyphs)
        let h = ceil(font.capHeight) + 9
        let size = NSSize(width: max(h + 2, ceil(t.width) + 10), height: h)
        let image = NSImage(size: size, flipped: false) { rect in
            let cap = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.06).setFill()
            cap.fill()
            NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.14).setStroke()
            cap.lineWidth = 1
            cap.stroke()
            (key as NSString).draw(at: NSPoint(x: (rect.width - t.width) / 2, y: (rect.height - t.height) / 2), withAttributes: glyphs)
            return true
        }
        cache[id] = image
        return image
    }
}

/// Borderless, non-activating panel whose content sits on system glass. Follows
/// the system appearance; all text uses semantic colours so it reads on both.
class GlassPanel: NSPanel {
    let content = Flipped()
    private let canKey: Bool

    init(cornerRadius: CGFloat, canBecomeKey: Bool) {
        canKey = canBecomeKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // Liquid Glass draws its own depth; the window shadow would trace the
        // square frame behind the rounded corners.
        if #available(macOS 26.0, *) { hasShadow = false } else { hasShadow = true }
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .none

        let glass: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            g.contentView = content
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.masksToBounds = true
            content.frame = v.bounds
            content.autoresizingMask = [.width, .height]
            v.addSubview(content)
            glass = v
        }
        contentView = glass
        E2E.adopt(self)
    }

    override var canBecomeKey: Bool { canKey && E2E.showsUI }

    /// Colours the glass itself where macOS has Liquid Glass; false where the caller must.
    @discardableResult
    func tint(_ colour: NSColor?) -> Bool {
        guard #available(macOS 26.0, *), let glass = contentView as? NSGlassEffectView else { return false }
        glass.tintColor = colour
        return true
    }

    /// Headless e2e runs keep every panel transparent and click-through.
    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set { super.alphaValue = E2E.showsUI ? newValue : 0 }
    }
}

/// One session: app icon, title, project and age, state, tokens.
final class SessionRow: Flipped {
    static let height: CGFloat = 54

    private let icon = NSImageView()
    private let title = label(14, .semibold)
    private let detail = label(12, .regular, .secondaryLabelColor)
    private let state = label(12, .semibold)
    private let tokens = label(11, .medium, .tertiaryLabelColor)
    private let unreadDot = NSView()
    private let stateDot = NSView()
    private(set) var session: Session?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        state.alignment = .right
        tokens.alignment = .right
        tokens.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        for dot in [unreadDot, stateDot] {
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
        }
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        [unreadDot, icon, title, detail, state, stateDot, tokens].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    /// The keys that answer this prompt, shown where the usage normally sits.
    static func answerHint(_ p: Prompt) -> String {
        let m = Hotkeys.shared.switcher.symbols.replacingOccurrences(of: "⇧", with: "")
        switch p.kind {
        case .permission: return "\(m)↩ Allow   \(m)⌫ Deny"
        case .question(_, let options): return "\(m)1–\(m)\(options.count) to answer"
        case .plan: return "\(m)↩ Approve   \(m)⌫ Keep planning"
        }
    }

    static func usageText(_ s: Session) -> String {
        guard s.tokens > 0 else { return "" }
        switch Settings.costDisplay {
        case .hidden: return ""
        case .tokens: return "\(compact(s.tokens)) tokens"
        case .costAndTokens:
            if let c = s.cost { return "≈ \(money(c)) API  ·  \(compact(s.tokens))" }
            return "\(compact(s.tokens)) tokens"
        }
    }

    /// `unfolded`: the alert lists the prompt's details below, so the row needn't squeeze them in.
    /// `trailing`: the answer keys or usage under the state; the alert has its own key line.
    func show(_ s: Session, now: Date, unfolded: Bool = false, trailing: Bool = true) {
        if session?.agent != s.agent { icon.image = s.agent.icon }
        session = s
        set(title, s.displayTitle)
        let prompt = s.promptID.flatMap { Prompts.shared.pending[$0] }
        if let p = prompt {
            let line = NSMutableAttributedString(string: p.headline + "  ", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)])
            let code: Bool
            if case .permission = p.kind { code = true } else { code = false }
            var inline = p.detail
            if unfolded, case .question = p.kind { inline = "" }
            line.append(NSAttributedString(string: inline, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: code ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium) : NSFont.systemFont(ofSize: 12, weight: .medium)]))
            let truncate = NSMutableParagraphStyle()
            truncate.lineBreakMode = .byTruncatingTail
            line.addAttribute(.paragraphStyle, value: truncate, range: NSRange(location: 0, length: line.length))
            if detail.attributedStringValue != line { detail.attributedStringValue = line }
        } else {
                detail.attributedStringValue = NSAttributedString(string: "")
            let when = s.fault?.resets.map { "resets \($0)" } ?? age(s.since, now: now)
            if let q = s.asking, s.status == .needsYou {
                set(detail, "Asks: " + q)
                detail.textColor = .labelColor
            } else {
                set(detail, [s.agent.name, s.projectName, when].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                detail.textColor = .secondaryLabelColor
            }
            detail.font = .systemFont(ofSize: 12)
        }
        set(state, s.stateLabel)
        state.textColor = s.status == .working ? .secondaryLabelColor : s.status.colour
        let working = s.status == .working
        // Colour means what to do: orange needs you, red failed, green done. Working is calm grey,
        // even for Claude, whose own orange would read as waiting on you; the icon says which agent.
        effectiveAppearance.performAsCurrentDrawingAppearance { stateDot.layer?.backgroundColor = s.status.colour.cgColor }
        stateDot.isHidden = s.status == .idle
        if working, stateDot.layer?.animation(forKey: "breathe") == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.25
            breathe.duration = 1.1
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stateDot.layer?.add(breathe, forKey: "breathe")
        } else if !working {
            stateDot.layer?.removeAnimation(forKey: "breathe")
        }
        set(tokens, trailing ? prompt.map(Self.answerHint) ?? Self.usageText(s) : "")
        let cost = s.cost.map { "≈ \(money($0)) at API list prices\(s.costPartial ? " (some models unpriced)" : "") · \(s.tokens.formatted()) tokens" }
        let tip = [s.asking, s.fault?.message, cost].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        toolTip = tip.isEmpty ? nil : tip
        unreadDot.isHidden = !s.unread
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([s.agent.name, s.displayTitle, s.stateLabel, s.fault?.resets.map { "resets \($0)" } ?? "", s.unread ? "unread" : "",
                               s.cost.map { "about \(money($0)) at API prices" } ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        unreadDot.frame = NSRect(x: 4, y: (h - 7) / 2, width: 7, height: 7)
        icon.frame = NSRect(x: 16, y: (h - 30) / 2, width: 30, height: 30)
        let right: CGFloat = 150
        title.frame = NSRect(x: 58, y: 9, width: w - 58 - right - 12, height: 18)
        detail.frame = NSRect(x: 58, y: 29, width: w - 58 - right - 12, height: 16)
        state.frame = NSRect(x: w - right - 14, y: 9, width: right, height: 16)
        let textWidth = state.attributedStringValue.size().width
        stateDot.frame = NSRect(x: w - 14 - textWidth - 12, y: 14, width: 7, height: 7)
        tokens.frame = NSRect(x: w - right - 14, y: 29, width: right, height: 15)
    }
}

/// Sectioned list with a selection highlight that glides between rows.
final class SessionList: Flipped {
    static let headerHeight: CGFloat = 28
    static let inset: CGFloat = 8

    private var rows: [SessionRow] = []
    private var headers: [NSTextField] = []
    private let highlight = NSView()
    private(set) var items: [Session] = []
    private var rowFrames: [NSRect] = []
    private(set) var selected = 0

    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 12
        addSubview(highlight)
    }

    required init?(coder: NSCoder) { nil }

    /// Height the list needs for these sessions.
    static func height(for sessions: [Session]) -> CGFloat {
        let sections = Set(sessions.map { $0.status.section }).count
        return CGFloat(sessions.count) * SessionRow.height + CGFloat(sections) * headerHeight + inset * 2
    }

    func show(_ sessions: [Session], selected: Int, animated: Bool = false) {
        items = sessions
        let now = Date()
        let w = bounds.width
        var y = Self.inset
        var headerIndex = 0, rowIndex = 0
        rowFrames = []
        var current: ListSection?
        for s in sessions {
            if s.status.section != current {
                current = s.status.section
                let h = header(headerIndex)
                let count = sessions.filter { $0.status.section == current }.count
                set(h, "\(current!.title)  \(count)")
                h.frame = NSRect(x: 18, y: y + 9, width: w - 36, height: 14)
                h.isHidden = false
                headerIndex += 1
                y += Self.headerHeight
            }
            let r = row(rowIndex)
            r.frame = NSRect(x: Self.inset, y: y, width: w - Self.inset * 2, height: SessionRow.height)
            r.show(s, now: now)
            r.isHidden = false
            rowFrames.append(r.frame)
            rowIndex += 1
            y += SessionRow.height
        }
        rows.dropFirst(rowIndex).forEach { $0.isHidden = true }
        headers.dropFirst(headerIndex).forEach { $0.isHidden = true }
        select(selected, animated: animated)
    }

    func select(_ index: Int, animated: Bool) {
        guard !items.isEmpty else { highlight.isHidden = true; return }
        selected = max(0, min(index, items.count - 1))
        highlight.isHidden = false
        // A plain fill, as Mac lists select. The row's own orange says when it waits on you;
        // an orange wash over the glass only turns muddy.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
        let target = rowFrames[selected]
        if animated, highlight.frame != .zero, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                highlight.frame = target
            }
        } else {
            highlight.frame = target
        }
    }

    func rowFrame(_ index: Int) -> NSRect? { rowFrames.indices.contains(index) ? rowFrames[index] : nil }

    func rowIndex(at point: NSPoint) -> Int? { rowFrames.firstIndex { $0.contains(point) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard onHover != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rowFrames.firstIndex(where: { $0.contains(p) }), i != selected { onHover?(i) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rowFrames.firstIndex(where: { $0.contains(p) }) { onClick?(i) }
    }

    private func row(_ i: Int) -> SessionRow {
        while rows.count <= i {
            let r = SessionRow(frame: .zero)
            addSubview(r)
            rows.append(r)
        }
        return rows[i]
    }

    private func header(_ i: Int) -> NSTextField {
        while headers.count <= i {
            let h = label(11, .semibold, .tertiaryLabelColor)
            addSubview(h)
            headers.append(h)
        }
        return headers[i]
    }
}
