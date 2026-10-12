import AppKit

/// Demo mode (`Muster --demo`): sample sessions and a sample prompt, for
/// screenshots and recordings. `--backdrop [--light]` adds a wallpaper behind the
/// panels so only it shows through the glass.
enum Demo {
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
