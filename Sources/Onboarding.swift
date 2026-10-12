import AppKit
import AVFoundation
import Combine
import SwiftUI
import UserNotifications

/// The first-run tour. Every step is done with the real app: the agents it finds,
/// the switcher you open, the hooks you turn on. Nothing is asked for before the
/// step that needs it, and every step can be skipped and replayed later.
final class Welcome {
    private let model = OnboardingModel()
    private let switcher: Switcher
    private let deck: Deck
    private let onClose: () -> Void
    private var window: NSWindow?
    private var flags: Any?
    private var tick: Timer?
    private var stepWatch: AnyCancellable?

    init(switcher: Switcher, deck: Deck, onClose: @escaping () -> Void) {
        self.switcher = switcher
        self.deck = deck
        self.onClose = onClose
        model.finish = { [weak self] in self?.close() }
        switcher.onShow = { [weak self] in self?.model.flashKey() }
        switcher.onPractice = { [weak self] in
            self?.model.triedSwitcher = true
            self?.window?.makeKeyAndOrderFront(nil)
        }
        deck.onShow = { [weak self] in self?.model.triedSearch = true }
        deck.onHide = { [weak self] in
            guard let w = self?.window, w.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        model.restart()
        let w = OnboardingWindow(model: model)
        w.onClosed = { [weak self] in self?.closed() }
        window = w
        stepWatch = model.$step.sink { [weak self] step in self?.switcher.practice = step == .tryIt }
        flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.model.held = e.modifierFlags.intersection([.control, .option, .shift, .command])
            return e
        }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.model.refresh() }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        if Store.demo, let screen = NSScreen.screens.first {
            w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            w.setFrameOrigin(NSPoint(x: screen.frame.midX - w.frame.width / 2, y: screen.frame.midY - w.frame.height / 2))
        }
        w.makeKeyAndOrderFront(nil)
    }

    private func close() { window?.close() }

    private func closed() {
        if model.reachedEnd, !Store.demo, model.openAtLogin != Settings.launchAtLogin { Settings.launchAtLogin = model.openAtLogin }
        UserDefaults.standard.set(true, forKey: "launched")
        switcher.practice = false
        if let flags { NSEvent.removeMonitor(flags) }
        flags = nil
        tick?.invalidate()
        tick = nil
        stepWatch = nil
        window = nil
        onClose()
    }
}

private final class OnboardingWindow: NSWindow, NSWindowDelegate {
    var onClosed: (() -> Void)?

    init(model: OnboardingModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Welcome to Muster"
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = NSHostingView(rootView: OnboardingView(model: model).background(Frosted().ignoresSafeArea()))
    }

    func windowWillClose(_ notification: Notification) { onClosed?() }
}

/// The desktop blurred behind the window, drawn under the content rather than
/// around it so text keeps full contrast.
private struct Frosted: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case hello, agents, tryIt, answer, notify }

    @Published private(set) var step: Step = .hello
    @Published private(set) var forward = true
    @Published private(set) var reachedEnd = false
    @Published private(set) var sources: [Agent: SourceState] = [:]
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    @Published private(set) var hooks: [Agent: Bool] = [:]
    @Published private(set) var broken: [String] = []
    @Published private(set) var keyDown = false
    @Published var triedSwitcher = false
    @Published var triedSearch = false
    @Published var held: NSEvent.ModifierFlags = []
    @Published var hookError: String?
    @Published var openAtLogin = true
    var finish: (() -> Void)?

    var steps: [Step] { Step.allCases.filter { $0 != .answer || !answerable.isEmpty } }
    var answerable: [Agent] { [.claude, .codex].filter(installed) }
    var position: Int { steps.firstIndex(of: step) ?? 0 }

    func installed(_ agent: Agent) -> Bool {
        switch sources[agent] {
        case .ok, .unreadable: return true
        case .notInstalled, nil: return false
        }
    }

    func restart() {
        step = .hello
        forward = true
        reachedEnd = false
        triedSwitcher = false
        triedSearch = false
        openAtLogin = true
    }

    func next() {
        guard position + 1 < steps.count else { finish?(); return }
        forward = true
        step = steps[position + 1]
        if step == .notify { reachedEnd = true }
    }

    func back() {
        guard position > 0 else { return }
        forward = false
        step = steps[position - 1]
    }

    func refresh() {
        sources = Store.shared.sources
        Notifier.status { [weak self] in self?.notifications = $0 }
        guard !Store.demo else { return }
        hooks = [.claude: HookInstaller.isInstalled(.claude), .codex: HookInstaller.isInstalled(.codex)]
        broken = HookInstaller.brokenClaudeHooks()
    }

    func flashKey() {
        keyDown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.keyDown = false }
    }

    func setHook(_ agent: Agent, _ on: Bool) {
        if Store.demo { hooks[agent] = on; return }
        do {
            try on ? HookInstaller.install(agent) : HookInstaller.uninstall(agent)
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refresh()
    }

    func removeBroken() {
        do {
            try HookInstaller.removeBrokenClaudeHooks()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refresh()
    }

    func allowNotifications() {
        if notifications == .denied {
            Notifier.openSystemSettings()
        } else {
            Notifier.requestAuthorization { [weak self] in self?.refresh() }
        }
    }
}

// MARK: views

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page.id(model.step).transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            bar
        }
        .frame(width: 580, height: 640)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86), value: model.step)
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .hello: HelloPage()
        case .agents: AgentsPage(model: model)
        case .tryIt: TryPage(model: model)
        case .answer: AnswerPage(model: model)
        case .notify: NotifyPage(model: model)
        }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let edge: Edge = model.forward ? .trailing : .leading
        return .asymmetric(insertion: .move(edge: edge).combined(with: .opacity),
                           removal: .move(edge: edge == .trailing ? .leading : .trailing).combined(with: .opacity))
    }

    private var bar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ForEach(model.steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == model.position ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                        .frame(width: i == model.position ? 18 : 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(model.position + 1) of \(model.steps.count)")
            Spacer()
            if model.position > 0 {
                Button("Back", action: model.back)
                    .controlSize(.large)
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            Button(action: model.next) {
                Text(primaryTitle).frame(minWidth: 110)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 8)
    }

    private var primaryTitle: String {
        switch model.step {
        case .hello: return "Get Started"
        case .notify: return "Done"
        default: return "Continue"
        }
    }
}

private struct Header: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}

private struct HelloPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)
            Group {
                if let url = Bundle.main.url(forResource: "intro", withExtension: "mp4") {
                    LoopingVideo(url: url, playing: !reduceMotion)
                        .frame(width: 396, height: 350)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                        .accessibilityLabel("The switcher opening over your work, listing agent sessions")
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
                }
            }
            VStack(spacing: 6) {
                Text("Muster").font(.system(size: 34, weight: .bold))
                Text("Every agent, one glance.").font(.system(size: 17)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
        }
    }
}

private struct AgentsPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 24)
            Header(title: "Your agents", subtitle: "Muster reads the sessions they already save on this Mac, so there's nothing to connect.")
            Card {
                ForEach(Array(Agent.allCases.enumerated()), id: \.element) { i, agent in
                    if i > 0 { Divider().padding(.leading, 62) }
                    AgentRow(agent: agent, state: model.sources[agent])
                }
            }
            .frame(width: 440)
            if Agent.allCases.allSatisfy({ !model.installed($0) }), !model.sources.isEmpty {
                Text("None yet. Your sessions show up here as soon as you start one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Label("Muster only reads these files, and nothing leaves your Mac.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 24)
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let state: SourceState?

    var body: some View {
        HStack(spacing: 14) {
            if let icon = agent.icon {
                Image(nsImage: icon).resizable().frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            badge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch state {
        case nil: return "Looking…"
        case .notInstalled: return "Not on this Mac. Muster picks it up when you install it."
        case .ok, .unreadable: return state!.summary
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case nil: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: state)
        case .unreadable: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange)
        case .notInstalled: Text("Not found").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
        }
    }
}

private struct TryPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var keys = Hotkeys.shared

    var body: some View {
        let s = keys.switcher
        VStack(spacing: 24) {
            Spacer(minLength: 24)
            Header(title: "Try it now", subtitle: "Hold \(s.symbols) and tap \(s.key). Let go to close.")
            Keycaps(shortcut: s, held: model.held, keyDown: model.keyDown)
                .padding(.vertical, 4)
            Group {
                if model.triedSwitcher {
                    Label("That's it. Letting go opens the session.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else {
                    Text("Your sessions show up while you hold \(s.symbols).")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.triedSwitcher)
            if let blocker = conflict(s) {
                ConflictCard(message: blocker)
            }
            Card {
                ShortcutRow(title: "Switch between sessions", shortcut: keys.switcher,
                            conflict: keys.conflicts.contains("switcher"), done: model.triedSwitcher) { keys.set(switcher: $0) }
                Divider().padding(.leading, 14)
                ShortcutRow(title: "Search every session", shortcut: keys.search,
                            conflict: keys.conflicts.contains("search"), done: model.triedSearch) { keys.set(search: $0) }
            }
            .frame(width: 440)
            Text("Click a shortcut to change it.").font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 24)
        }
    }

    private func conflict(_ s: Shortcut) -> String? {
        if keys.conflicts.contains("switcher") { return "\(s.display) is already taken by another app." }
        if s == .switcherDefault, let app = Conflicts.runningSwitcherApp() { return "\(app) also uses \(s.display)." }
        return nil
    }
}

private struct ConflictCard: View {
    let message: String
    @ObservedObject private var keys = Hotkeys.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
            Button("Use \(Shortcut.switcherAlternative.display)") { keys.set(switcher: .switcherAlternative) }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: 440)
    }
}

private struct ShortcutRow: View {
    let title: String
    let shortcut: Shortcut
    let conflict: Bool
    let done: Bool
    let onChange: (Shortcut) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .symbolEffect(.bounce, value: done)
            Text(title).font(.system(size: 13))
            Spacer()
            ShortcutRecorder(shortcut: shortcut, conflict: conflict, onChange: onChange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct Keycaps: View {
    let shortcut: Shortcut
    let held: NSEvent.ModifierFlags
    let keyDown: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(modifiers, id: \.symbol) { m in
                Keycap(label: m.symbol, caption: m.name, width: 70, pressed: held.contains(m.flag))
            }
            Keycap(label: shortcut.key, caption: nil, width: shortcut.key.count > 1 ? 110 : 70, pressed: keyDown)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcut \(shortcut.display)")
    }

    private var modifiers: [(symbol: String, name: String, flag: NSEvent.ModifierFlags)] {
        [("⌃", "control", NSEvent.ModifierFlags.control), ("⌥", "option", .option), ("⇧", "shift", .shift), ("⌘", "command", .command)]
            .filter { shortcut.flags.contains($0.2) }
    }
}

private struct Keycap: View {
    let label: String
    let caption: String?
    let width: CGFloat
    let pressed: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: caption == nil ? 20 : 24, weight: .medium, design: .rounded))
            if let caption { Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
        }
        .frame(width: width, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(pressed ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06))
                .shadow(color: .black.opacity(pressed ? 0 : 0.18), radius: 0, y: pressed ? 0 : 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(pressed ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12)))
        .offset(y: pressed ? 2 : 0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressed)
    }
}

private struct AnswerPage: View {
    @ObservedObject var model: OnboardingModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)
            Header(title: "Answer without switching",
                   subtitle: "When an agent asks to run something, reply from Muster or right from the notification.")
            PromptPreview()
            Card {
                ForEach(Array(model.answerable.enumerated()), id: \.element) { i, agent in
                    if i > 0 { Divider().padding(.leading, 62) }
                    hookRow(agent)
                }
            }
            .frame(width: 460)
            if let error = model.hookError {
                Text(error).font(.callout).foregroundStyle(.orange).frame(width: 460, alignment: .leading)
            }
            if !model.broken.isEmpty { brokenNote }
            if model.installed(.cursor) {
                Text("Cursor prompts open in Cursor.").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 24)
        }
    }

    private func hookRow(_ agent: Agent) -> some View {
        let on = model.hooks[agent] ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if let icon = agent.icon { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent == .claude ? "Claude Code" : "Codex").font(.system(size: 14, weight: .semibold))
                    Text(agent == .claude ? "Permissions, questions and plans" : "Approvals")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { model.setHook(agent, $0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Answer \(agent.name) prompts from Muster")
            }
            Text("Adds one hook to \(HookInstaller.displayPath(agent)) and keeps a backup.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.leading, 48)
            if agent == .codex, on {
                HStack(spacing: 8) {
                    Text("Then run /hooks in Codex once to trust it.").font(.system(size: 12))
                    Button(copied ? "Copied" : "Copy /hooks") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/hooks", forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var brokenNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.broken.joined(separator: ", ")) is gone, but its Claude hooks still run and fail.")
                    .font(.callout)
                Text("Removing them keeps a backup.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove", action: model.removeBroken)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(width: 460)
    }
}

private struct PromptPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            if let icon = Agent.claude.icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude · Wants to run").font(.system(size: 13, weight: .semibold))
                Text("npm test").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Allow").padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                Text("Deny").padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(14)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: Claude wants to run npm test, with Allow and Deny buttons")
    }
}

private struct NotifyPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 24)
            Header(title: "Stay in the loop", subtitle: "Muster notifies you when an agent needs you and stays quiet otherwise.")
            Card {
                HStack(spacing: 14) {
                    icon("bell.badge.fill", .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications").font(.system(size: 14, weight: .semibold))
                        Text("A banner when an agent waits on you, with Allow and Deny on it.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    notificationControl
                }
                .padding(14)
                Divider().padding(.leading, 62)
                HStack(spacing: 14) {
                    icon("power", .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login").font(.system(size: 14, weight: .semibold))
                        Text("Muster starts quietly in your menu bar.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.openAtLogin).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Open at login")
                }
                .padding(14)
            }
            .frame(width: 460)
            Spacer(minLength: 24)
        }
    }

    private func icon(_ name: String, _ colour: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(colour.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var notificationControl: some View {
        switch model.notifications {
        case .authorized, .provisional, .ephemeral:
            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 13, weight: .medium))
        case .denied:
            Button("Open Settings", action: model.allowNotifications)
        default:
            Button("Allow", action: model.allowNotifications)
        }
    }
}

private struct LoopingVideo: NSViewRepresentable {
    let url: URL
    let playing: Bool

    func makeNSView(context: Context) -> PlayerView { PlayerView(url: url, playing: playing) }
    func updateNSView(_ view: PlayerView, context: Context) {}
}

private final class PlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL, playing: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        if playing { player.play() }
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        return layer
    }
}

// MARK: launch edge cases

enum Conflicts {
    /// Window switchers that grab ⌥Tab with an event tap, which a Carbon hot key can't detect.
    private static let switchers = ["com.lwouis.alt-tab-macos": "AltTab"]

    static func runningSwitcherApp() -> String? {
        NSWorkspace.shared.runningApplications.lazy.compactMap { $0.bundleIdentifier.flatMap { switchers[$0] } }.first
    }
}

enum Installer {
    static let reopen = Notification.Name("dev.muster.app.reopen")

    /// Another Muster is already running: hand over to it and quit.
    static func handOffIfRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) else { return false }
        DistributedNotificationCenter.default().postNotificationName(reopen, object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }

    /// Running from the disk image, a translocated copy or Downloads: offer to move to Applications.
    static func offerMove() -> Bool {
        let fm = FileManager.default
        let path = Bundle.main.bundlePath
        let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path + "/"
        let translocated = path.contains("/AppTranslocation/")
        let mounted = path.hasPrefix("/Volumes/")
        guard Bundle.main.bundleIdentifier != nil, translocated || mounted || path.hasPrefix(downloads) else { return false }

        let alert = NSAlert()
        alert.messageText = "Move Muster to Applications?"
        alert.informativeText = "From Applications, Muster can open at login and stays where you expect it."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let system = URL(fileURLWithPath: "/Applications")
        let folder = fm.isWritableFile(atPath: system.path) ? system : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let dest = folder.appendingPathComponent("Muster.app")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Muster couldn't be moved"
            failed.informativeText = error.localizedDescription
            failed.runModal()
            return false
        }
        if !translocated && !mounted { try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"", dest.path]
        try? relaunch.run()
        return true
    }
}
