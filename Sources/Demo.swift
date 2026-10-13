import AppKit

/// Demo mode (`Muster --demo`): sample sessions and a sample prompt, for
/// screenshots and recordings. `--backdrop [--light]` adds a wallpaper behind the
/// panels so only it shows through the glass.
enum Demo {
    /// `--autoplay [answer|switcher|search]`: a scene Muster plays by itself, with the keys drawn
    /// on screen the way screencast tools show them, so recording it needs Screen Recording and
    /// no synthetic keystrokes. The scripts that record them are scripts/record-*.sh.
    ///   answer    Claude asks, then Codex; ⌥↓ unfolds why Codex asks, ⌥↩ answers each.
    ///   switcher  ⌥Tab through the sessions and back, ⌥↩ answers the one waiting, ⌥Tab again.
    ///   search    ⌃⌥Space, then typing narrows the list.
    static let scene: String? = {
        let args = CommandLine.arguments
        guard Store.demo, let i = args.firstIndex(of: "--autoplay") else { return nil }
        let next = i + 1 < args.count ? args[i + 1] : ""
        return ["switcher", "search"].contains(next) ? next : "answer"
    }()
    static var autoplay: Bool { scene == "answer" }
    /// The switcher's modifiers, held down by the scene rather than by a hand.
    static var holding = false
    private static var caps: KeyCaps?

    static func play(answer: @escaping (Answer) -> Void, switcher: Switcher, deck: Deck) {
        // `--peek` (with `--attention`): the alert opens with its details unfolded, for screenshots.
        if Store.demo, CommandLine.arguments.contains("--peek") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: Attention.peekRequest, object: NSNumber(value: true))
            }
        }
        // `--switcher` or `--search`: that panel opens and stays, for screenshots.
        if Store.demo, CommandLine.arguments.contains("--switcher") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { holding = true; switcher.step(1); report(switcher.frame) }
        }
        if Store.demo, CommandLine.arguments.contains("--search") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { deck.toggle(below: nil); report(deck.frame) }
        }
        // `--attention`: where the alert is, once it's up.
        if Store.demo, scene == nil, CommandLine.arguments.contains("--attention") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                if let alert = NSApp.windows.first(where: { $0.identifier?.rawValue == "muster.alert" && $0.isVisible }) { report(alert.frame) }
            }
        }
        let steps: [(TimeInterval, () -> Void)]
        switch scene {
        case "answer": steps = answerScene(answer)
        case "switcher": steps = switcherScene(switcher)
        case "search": steps = searchScene(deck)
        default: return
        }
        for (t, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: step) }
    }

    private static func answerScene(_ answer: @escaping (Answer) -> Void) -> [(TimeInterval, () -> Void)] {
        let keys = KeyCaps(["⌥", "↓"], room: [1: ["↩"]])
        caps = keys
        let ask = { (agent: Agent) in Prompts.shared.addDemoPrompt(agent); Store.shared.refreshPrompts() }
        let peek = { NotificationCenter.default.post(name: Attention.peekRequest, object: NSNumber(value: true)) }
        return [
            (3.0, { ask(.claude) }),
            (4.1, { ask(.codex) }),
            (5.0, { keys.show() }),
            (5.7, { keys.press(); peek() }),
            (7.5, { keys.label(1, "↩") }),
            (7.9, { keys.press(); answer(.allow) }),
            (9.4, { keys.press(); answer(.allow) }),
            (10.4, { keys.hide() }),
        ]
    }

    private static func switcherScene(_ switcher: Switcher) -> [(TimeInterval, () -> Void)] {
        let keys = KeyCaps(["⌥", "Tab"], room: [1: ["⇧Tab", "↩", "Esc"]])
        caps = keys
        let tab = { (label: String, delta: Int) in keys.label(1, label); keys.press([1]); switcher.step(delta) }
        let hold = { (on: Bool) in holding = on; keys.hold(0, on) }
        return [
            (1.2, { hold(true); switcher.step(1); keys.show(below: switcher.frame); keys.press([1]) }),
            (1.6, { report(switcher.frame.union(keys.frame)) }),
            (2.4, { tab("Tab", 1) }),
            (3.1, { tab("Tab", 1) }),
            (3.9, { tab("⇧Tab", -1) }),
            (4.6, { tab("⇧Tab", -1) }),
            (5.6, { keys.label(1, "↩"); keys.press([1]); switcher.answer(.allow) }),
            (6.0, { hold(false) }),
            (6.9, { keys.label(1, "Tab"); hold(true); keys.press([1]); switcher.step(1) }),
            (8.6, { keys.label(1, "Esc"); keys.press([1]); switcher.cancel() }),
            (8.9, { hold(false) }),
            (9.6, { keys.hide() }),
        ]
    }

    private static func searchScene(_ deck: Deck) -> [(TimeInterval, () -> Void)] {
        let keys = KeyCaps(["⌃", "⌥", "Space"])
        caps = keys
        return [
            (1.0, { keys.show(below: deck.plannedFrame) }),
            (1.5, { keys.press(); deck.toggle(below: nil) }),
            (1.9, { report(deck.frame.union(keys.frame)) }),
            (2.4, { keys.hide() }),
            (2.9, { deck.type("r") }),
            (3.05, { deck.type("ru") }),
            (3.2, { deck.type("rus") }),
            (3.35, { deck.type("rust") }),
            (5.3, { deck.type("") }),
            (6.4, { deck.hide() }),
        ]
    }

    /// The area a scene uses, in screen points from the top left, for the recording script to crop to.
    private static func report(_ r: NSRect) {
        guard let screen = NSScreen.screens.first else { return }
        print("scene \(Int(r.minX)) \(Int(screen.frame.maxY - r.maxY)) \(Int(r.width)) \(Int(r.height))")
        fflush(stdout)
    }

    /// A full-screen wallpaper window behind the panels, so screenshots of the real
    /// glass show only the wallpaper through it. `Muster --demo --backdrop [--light]`.
    private static var backdrop: NSWindow?
    static func showBackdrop() {
        guard let screen = NSScreen.screens.first else { return }
        let dark = !CommandLine.arguments.contains("--light")
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.ignoresMouseEvents = true
        let view = NSImageView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = wallpaper(size: screen.frame.size, dark: dark)
        view.imageScaling = .scaleAxesIndependently
        w.contentView = view
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.orderFrontRegardless()
        backdrop = w
    }

    /// Calm blues, like a Mac desktop, so the only warm colour on screen is the orange that
    /// means an agent needs you.
    static func wallpaper(size: NSSize, dark: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let stops: [NSColor] = dark
                ? [NSColor(srgbRed: 0.06, green: 0.12, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.03, green: 0.07, blue: 0.15, alpha: 1)]
                : [NSColor(srgbRed: 0.55, green: 0.70, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.76, green: 0.84, blue: 0.96, alpha: 1)]
            NSGradient(colors: stops)!.draw(in: r, angle: -35)
            let blobs: [(NSColor, NSPoint, CGFloat, CGFloat)] = dark
                ? [(NSColor(srgbRed: 0.18, green: 0.42, blue: 0.95, alpha: 1), NSPoint(x: 0.22, y: 0.78), 0.55, 0.5),
                   (NSColor(srgbRed: 0.08, green: 0.62, blue: 0.78, alpha: 1), NSPoint(x: 0.82, y: 0.28), 0.5, 0.38),
                   (NSColor(srgbRed: 0.28, green: 0.32, blue: 0.78, alpha: 1), NSPoint(x: 0.6, y: 0.95), 0.38, 0.3)]
                : [(NSColor(srgbRed: 0.28, green: 0.50, blue: 0.95, alpha: 1), NSPoint(x: 0.2, y: 0.3), 0.5, 0.45),
                   (NSColor(srgbRed: 0.40, green: 0.80, blue: 0.90, alpha: 1), NSPoint(x: 0.85, y: 0.75), 0.45, 0.4),
                   (NSColor(srgbRed: 0.90, green: 0.94, blue: 1.00, alpha: 1), NSPoint(x: 0.5, y: 0.98), 0.45, 0.5)]
            for (c, p, radius, alpha) in blobs {
                let g = NSGradient(colors: [c.withAlphaComponent(alpha), c.withAlphaComponent(0)])!
                g.draw(fromCenter: NSPoint(x: r.width * p.x, y: r.height * p.y), radius: 0,
                       toCenter: NSPoint(x: r.width * p.x, y: r.height * p.y), radius: r.width * radius, options: [])
            }
            return true
        }
    }
}

/// Keycaps in recordings, the way screencast tools show what was pressed.
private final class KeyCaps {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var keys: [CALayer] = []
    private var texts: [CATextLayer] = []
    private static let side: CGFloat = 60, gap: CGFloat = 10
    private static let font = NSFont.systemFont(ofSize: 26, weight: .medium)

    /// `room`: other labels a key will show, so it's wide enough for them from the start.
    init(_ labels: [String], room: [Int: [String]] = [:]) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let widths = labels.enumerated().map { i, label in
            ([label] + (room[i] ?? [])).map { max(Self.side, ceil(($0 as NSString).size(withAttributes: [.font: Self.font]).width) + 30) }.max() ?? Self.side
        }
        let width = widths.reduce(0, +) + CGFloat(labels.count - 1) * Self.gap
        panel.setContentSize(NSSize(width: width + 40, height: Self.side + 40))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        var x: CGFloat = 20
        for (i, label) in labels.enumerated() {
            let cap = CAGradientLayer()
            cap.frame = CGRect(x: x, y: 22, width: widths[i], height: Self.side)
            x += widths[i] + Self.gap
            cap.cornerRadius = 14
            cap.colors = dark ? [NSColor(white: 0.17, alpha: 1).cgColor, NSColor(white: 0.115, alpha: 1).cgColor]
                              : [NSColor.white.cgColor, NSColor(white: 0.945, alpha: 1).cgColor]
            cap.borderWidth = 1
            cap.borderColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.1)).cgColor
            cap.shadowColor = NSColor.black.cgColor
            cap.shadowOpacity = dark ? 0.7 : 0.25
            cap.shadowRadius = 10
            cap.shadowOffset = CGSize(width: 0, height: -6)
            let text = CATextLayer()
            text.string = label
            text.font = Self.font
            text.fontSize = 26
            text.alignmentMode = .center
            text.foregroundColor = (dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.11, alpha: 1)).cgColor
            text.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2
            text.frame = CGRect(x: 0, y: (Self.side - 34) / 2, width: widths[i], height: 34)
            cap.addSublayer(text)
            root.layer?.addSublayer(cap)
            keys.append(cap)
            texts.append(text)
        }
        panel.contentView = root
    }

    var frame: NSRect { panel.frame }

    /// Centred under a panel, or under where the alert sits, clear of it even unfolded.
    func show(below other: NSRect? = nil) {
        guard let area = NSScreen.screens.first?.visibleFrame else { return }
        let size = panel.frame.size
        let top = other.map { $0.minY - 18 } ?? area.maxY - 8 - 170 - 24
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: top - size.height))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 1 }
    }

    func label(_ i: Int, _ text: String) {
        guard texts.indices.contains(i) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        texts[i].string = text
        CATransaction.commit()
    }

    private static let pressed = CATransform3DConcat(CATransform3DMakeScale(0.93, 0.93, 1), CATransform3DMakeTranslation(0, -4, 0))

    /// Down, held long enough to read in a 20 fps GIF, then up. All the keys unless told which.
    func press(_ which: [Int]? = nil) {
        for i in which ?? Array(keys.indices) where keys.indices.contains(i) {
            let down = CAKeyframeAnimation(keyPath: "transform")
            down.values = [CATransform3DIdentity, Self.pressed, Self.pressed, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
            down.keyTimes = [0, 0.25, 0.7, 1]
            down.duration = 0.42
            keys[i].add(down, forKey: "press")
            let dim = CAKeyframeAnimation(keyPath: "opacity")
            dim.values = [1, 0.72, 0.72, 1]
            dim.keyTimes = [0, 0.25, 0.7, 1]
            dim.duration = 0.42
            keys[i].add(dim, forKey: "dim")
        }
    }

    /// A modifier held down until let go.
    func hold(_ i: Int, _ down: Bool) {
        guard keys.indices.contains(i) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        keys[i].transform = down ? Self.pressed : CATransform3DIdentity
        keys[i].opacity = down ? 0.72 : 1
        CATransaction.commit()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) { [panel] in panel.orderOut(nil) }
    }
}
