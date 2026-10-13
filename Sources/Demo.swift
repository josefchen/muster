import AppKit

/// Demo mode (`Muster --demo`): sample sessions and a sample prompt, for
/// screenshots and recordings. `--backdrop [--light]` adds a wallpaper behind the
/// panels so only it shows through the glass.
enum Demo {
    /// `--autoplay` (with `--attention`): the scene scripts/record-answer.sh records. Claude
    /// asks, then Codex, and ⌥↩ answers each, with the keys drawn under the alert. Muster
    /// plays it itself, so recording needs no synthetic keystrokes.
    static let autoplay = Store.demo && CommandLine.arguments.contains("--autoplay")
    private static var caps: KeyCaps?

    static func play(answer: @escaping (Answer) -> Void) {
        guard autoplay else { return }
        let keys = KeyCaps(["⌥", "↩"])
        caps = keys
        let ask = { (agent: Agent) in Prompts.shared.addDemoPrompt(agent); Store.shared.refreshPrompts() }
        let steps: [(TimeInterval, () -> Void)] = [
            (3.0, { ask(.claude) }),
            (4.1, { ask(.codex) }),
            (5.0, { keys.show() }),
            (5.9, { keys.press(); answer(.allow) }),
            (7.5, { keys.press(); answer(.allow) }),
            (8.6, { keys.hide() }),
        ]
        for (t, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: step) }
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

    static func wallpaper(size: NSSize, dark: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            let stops: [NSColor] = dark
                ? [NSColor(srgbRed: 0.10, green: 0.07, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.03, green: 0.12, blue: 0.24, alpha: 1)]
                : [NSColor(srgbRed: 0.98, green: 0.80, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.70, green: 0.80, blue: 0.98, alpha: 1)]
            NSGradient(colors: stops)!.draw(in: r, angle: -35)
            let blobs: [(NSColor, NSPoint, CGFloat)] = dark
                ? [(.systemPurple, NSPoint(x: 0.25, y: 0.7), 0.55), (.systemBlue, NSPoint(x: 0.8, y: 0.3), 0.5), (.systemOrange, NSPoint(x: 0.6, y: 0.85), 0.35)]
                : [(.systemOrange, NSPoint(x: 0.2, y: 0.25), 0.5), (.systemPurple, NSPoint(x: 0.85, y: 0.75), 0.45), (.systemBlue, NSPoint(x: 0.55, y: 0.15), 0.4)]
            for (c, p, s) in blobs {
                let g = NSGradient(colors: [c.withAlphaComponent(dark ? 0.55 : 0.45), c.withAlphaComponent(0)])!
                g.draw(fromCenter: NSPoint(x: r.width * p.x, y: r.height * p.y), radius: 0,
                       toCenter: NSPoint(x: r.width * p.x, y: r.height * p.y), radius: r.width * s, options: [])
            }
            return true
        }
    }
}

/// Keycaps under the alert in recordings, the way screencast tools show what was pressed.
private final class KeyCaps {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var keys: [CALayer] = []
    private static let side: CGFloat = 60, gap: CGFloat = 10

    init(_ labels: [String]) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let width = CGFloat(labels.count) * Self.side + CGFloat(labels.count - 1) * Self.gap
        panel.setContentSize(NSSize(width: width + 40, height: Self.side + 40))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        for (i, label) in labels.enumerated() {
            let cap = CAGradientLayer()
            cap.frame = CGRect(x: 20 + CGFloat(i) * (Self.side + Self.gap), y: 22, width: Self.side, height: Self.side)
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
            text.font = NSFont.systemFont(ofSize: 26, weight: .medium)
            text.fontSize = 26
            text.alignmentMode = .center
            text.foregroundColor = (dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.11, alpha: 1)).cgColor
            text.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2
            text.frame = CGRect(x: 0, y: (Self.side - 34) / 2, width: Self.side, height: 34)
            cap.addSublayer(text)
            root.layer?.addSublayer(cap)
            keys.append(cap)
        }
        panel.contentView = root
    }

    /// Centred under where the alert sits on the main screen.
    func show() {
        guard let area = NSScreen.screens.first?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - 8 - 86 - 28 - size.height))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 1 }
    }

    /// Down, held long enough to read in a 20 fps GIF, then up.
    func press() {
        let pressed = CATransform3DConcat(CATransform3DMakeScale(0.93, 0.93, 1), CATransform3DMakeTranslation(0, -4, 0))
        for cap in keys {
            let down = CAKeyframeAnimation(keyPath: "transform")
            down.values = [CATransform3DIdentity, pressed, pressed, CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
            down.keyTimes = [0, 0.25, 0.7, 1]
            down.duration = 0.42
            cap.add(down, forKey: "press")
            let dim = CAKeyframeAnimation(keyPath: "opacity")
            dim.values = [1, 0.72, 0.72, 1]
            dim.keyTimes = [0, 0.25, 0.7, 1]
            dim.duration = 0.42
            cap.add(dim, forKey: "dim")
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) { [panel] in panel.orderOut(nil) }
    }
}
