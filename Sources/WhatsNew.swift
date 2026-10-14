import AppKit
import SwiftUI

/// What changed in this version: once after an update, and from the menu bar menu.
/// Read from the CHANGELOG.md inside the app, so it works offline and nothing
/// leaves the Mac. Built only when shown.
final class WhatsNew {
    static let shared = WhatsNew()
    static let allChanges = URL(string: "https://agentmuster.app/changelog")!
    private static let seenKey = "whatsNew.seen"

    private var window: WhatsNewWindow?
    /// The version on screen, for the e2e state.
    private(set) var showing: String?

    var available: Bool { Changelog.current(Updates.version, in: Changelog.bundled) != nil }

    /// Once per update. A first launch gets the tour instead and only records the version.
    /// `--demo --whats-new` shows it for screenshots without touching what you've seen.
    func showIfUpdated() {
        if Store.demo {
            if CommandLine.arguments.contains("--whats-new") { show() }
            return
        }
        let d = UserDefaults.standard
        let version = Updates.version
        let seen = d.string(forKey: Self.seenKey)
        d.set(version, forKey: Self.seenKey)
        if let r = Changelog.afterUpdate(to: version, seen: seen, launchedBefore: d.bool(forKey: "launched"), in: Changelog.bundled) {
            show(r)
        }
    }

    func show(_ release: Release? = nil) {
        guard let release = release ?? Changelog.current(Updates.version, in: Changelog.bundled) else { return }
        if let window, showing == release.version { return present(window) }
        window?.close()
        let w = WhatsNewWindow(release: release)
        w.onClosed = { [weak self] in
            self?.window = nil
            self?.showing = nil
        }
        window = w
        showing = release.version
        present(w)
    }

    private func present(_ w: NSWindow) {
        // Headless e2e runs keep it off screen and leave your focus alone.
        guard E2E.showsUI else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

private final class WhatsNewWindow: NSWindow, NSWindowDelegate {
    var onClosed: (() -> Void)?

    init(release: Release) {
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "What's New in Muster"
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        let host = { (scrolls: Bool) in
            NSHostingView(rootView: WhatsNewView(release: release, scrolls: scrolls) { [weak self] in self?.close() }
                .background(Frosted().ignoresSafeArea()))
        }
        // A long release scrolls rather than run off a small screen.
        let fit = host(false).fittingSize
        let limit = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        contentView = host(fit.height > limit)
        setContentSize(NSSize(width: fit.width, height: min(fit.height, limit)))
    }

    // Muster has no main menu, so Esc and ⌘W are handled here.
    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?()
        DispatchQueue.main.async { self.contentView = nil }
    }
}

private struct WhatsNewView: View {
    let release: Release
    var scrolls = false
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)
                .padding(.top, 26)
            Text("VERSION \(release.shortVersion)")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
            Text("What's New in Muster")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 4)
            if !release.headline.isEmpty {
                Text(inline(release.headline))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .padding(.top, 6)
            }
            if scrolls {
                ScrollView { changes.padding(.bottom, 8) }
                    .padding(.top, 22)
                    .frame(maxHeight: .infinity)
            } else {
                changes.padding(.top, 30)
            }
            footer
        }
        .frame(width: 520)
    }

    private var changes: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(release.items) { ItemRow(item: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 44)
            ForEach(release.notes, id: \.self) { note in
                Card {
                    Text(inline(note))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }
                .padding(.horizontal, 44)
                .padding(.top, 20)
            }
        }
    }

    /// Without the daily check nothing tells you about the next release, so the window you
    /// see after updating offers it, ticked; Continue turns it on.
    private let offerUpdates = !Updates.automatic && !E2E.on
    @State private var updates = true

    private var footer: some View {
        HStack(spacing: 16) {
            Button("All Changes") { NSWorkspace.shared.open(WhatsNew.allChanges) }
                .buttonStyle(.link)
            Spacer()
            if offerUpdates {
                Toggle("Tell me about new versions", isOn: $updates)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Asks GitHub once a day whether there's a newer Muster. Nothing else is sent.")
            }
            Button(action: { if offerUpdates && updates { Updates.automatic = true }; close() }) { Text("Continue").frame(minWidth: 110) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }
}

private struct ItemRow: View {
    let item: Release.Item

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .semibold))
                Text(inline(item.body))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private func inline(_ markdown: String) -> AttributedString {
    (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
}
