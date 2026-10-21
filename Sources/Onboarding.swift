import AppKit
import AVFoundation
import Carbon.HIToolbox
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
        HookSetup.shared.stopChecking()
        if model.reachedEnd, !Store.demo, model.openAtLogin != Settings.launchAtLogin { Settings.launchAtLogin = model.openAtLogin }
        if model.reachedEnd, !Store.demo, !E2E.on, model.checkUpdates != Updates.automatic { Updates.automatic = model.checkUpdates }
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
struct Frosted: NSViewRepresentable {
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
    @Published private(set) var changing: Set<Agent> = []
    @Published private(set) var broken: [String] = []
    @Published private(set) var keyDown = false
    @Published var triedSwitcher = false
    @Published var triedSearch = false
    @Published var held: NSEvent.ModifierFlags = []
    @Published var hookError: String?
    @Published var openAtLogin = true
    @Published var checkUpdates = true
    var finish: (() -> Void)?

    init(startAt: Step = .hello) { step = startAt }

    var steps: [Step] { Step.allCases.filter { $0 != .answer || !answerable.isEmpty } }
    var answerable: [Agent] { [.claude, .codex].filter(installed) }
    var pendingAnswering: [Agent] { answerable.filter { hooks[$0] == true && HookSetup.shared.check($0).phase() != .verified } }
    var canContinue: Bool { step != .answer || pendingAnswering.isEmpty }
    var continueTitle: String {
        switch step {
        case .hello: return "Get Started"
        case .notify: return pendingAnswering.isEmpty ? "Use Muster" : "Finish later"
        case .answer: return answerable.contains(where: { hooks[$0] == true }) ? "Continue" : "Use switching only"
        default: return "Continue"
        }
    }
    var position: Int { steps.firstIndex(of: step) ?? 0 }

    func installed(_ agent: Agent) -> Bool {
        switch sources[agent] {
        case .ok, .unreadable: return true
        case .notInstalled, nil: return agent.appURL != nil
        }
    }

    func restart() {
        step = Self.demoStep ?? .hello
        forward = true
        reachedEnd = false
        triedSwitcher = false
        triedSearch = false
        openAtLogin = UserDefaults.standard.bool(forKey: "launched") ? Settings.launchAtLogin : true
        checkUpdates = UserDefaults.standard.bool(forKey: "launched") ? Updates.automatic : true
    }

    /// `--demo --step 3` opens the tour on that page (0 is hello), for screenshots.
    private static let demoStep: Step? = {
        let args = CommandLine.arguments
        guard Store.demo, let i = args.firstIndex(of: "--step"), i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
        return Step(rawValue: n)
    }()

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

    func revisitAnswering() { forward = false; step = .answer }
    func revisitShortcuts() { forward = false; step = .tryIt }
    func skipAnswering() { HookSetup.shared.stopChecking(); next() }

    func refresh() {
        sources = Store.shared.sources
        Notifier.status { [weak self] in self?.notifications = $0 }
        guard !Store.demo else { return }
        HookSetup.shared.refresh()
        // A switch being changed keeps what it shows until the change finishes.
        for agent in [Agent.claude, .codex] where !changing.contains(agent) { hooks[agent] = HookInstaller.isInstalled(agent) }
        broken = HookInstaller.brokenClaudeHooks()
    }

    func flashKey() {
        keyDown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in self?.keyDown = false }
    }

    func setHook(_ agent: Agent, _ on: Bool) {
        if Store.demo { hooks[agent] = on; return }
        hooks[agent] = on
        changing.insert(agent)
        HookInstaller.set(agent, on) { [weak self] error in
            guard let self else { return }
            hookError = error?.localizedDescription
            changing.remove(agent)
            refresh()
        }
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
    @ObservedObject private var setup = HookSetup.shared
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
                    .keyboardShortcut("[", modifiers: .command)
            }
            if model.step == .answer, !model.pendingAnswering.isEmpty {
                Button("Set up later", action: model.skipAnswering)
                    .controlSize(.large)
            }
            Button(action: model.next) {
                Text(model.continueTitle).frame(minWidth: 110)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canContinue)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 8)
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

struct Card<Content: View>: View {
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
                Text("Never keep an agent waiting.").font(.system(size: 17)).foregroundStyle(.secondary)
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
        case .notInstalled: return agent.appURL == nil ? "Not on this Mac. Muster picks it up when you install it." : "No saved sessions yet. Start one to see it here."
        case .ok, .unreadable: return state!.summary
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case nil: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: state)
        case .unreadable: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange)
        case .notInstalled: Text(agent.appURL == nil ? "Not found" : "No sessions yet").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
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

    @State private var showPreview = false
    @State private var selectedAgent: Agent = .codex

    private var currentAgent: Agent? { model.answerable.first(where: { $0 == selectedAgent }) ?? model.answerable.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Header(title: "Connect approvals",
                       subtitle: "Switching and search already work. Connect an agent below to answer its requests from Muster.")
                    .padding(.top, 24)
                if model.answerable.count > 1 {
                    Picker("Agent to connect", selection: $selectedAgent) {
                        ForEach(model.answerable, id: \.self) { agent in
                            Text(agent == .claude ? "Claude Code" : agent.name).tag(agent)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 460)
                }
                if let agent = currentAgent {
                    Card { hookRow(agent) }.frame(width: 460)
                }
                if let error = model.hookError {
                    Text(error).font(.callout).foregroundStyle(.orange).frame(width: 460, alignment: .leading)
                }
                if !model.broken.isEmpty { brokenNote }
                if model.installed(.cursor) {
                    Text("Cursor prompts open in Cursor.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Practice the keys with a sample alert", isExpanded: $showPreview) {
                    VStack(spacing: 10) {
                        Text("This is a sample. It does not verify your hooks.")
                            .font(.caption).foregroundStyle(.secondary)
                        PromptPreview()
                    }.padding(.top, 10)
                }
                .frame(width: 460)
                Text("Muster verifies each connection only after a request arrives, you answer from Muster, and that session resumes. You can finish later in Settings.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 460, alignment: .leading)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func hookRow(_ agent: Agent) -> some View {
        let on = model.hooks[agent] ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if let icon = agent.icon { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent == .claude ? "Claude Code" : "Codex").font(.system(size: 14, weight: .semibold))
                    Text(on ? "Hook installed; check its connection below" : (agent == .claude ? "Permissions, questions and plans" : "Approvals"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { model.setHook(agent, $0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(model.changing.contains(agent))
                    .accessibilityLabel("Answer \(agent.name) prompts from Muster")
            }
            Text(HookInstaller.relayAlone(agent) || HookInstaller.sharedWithRelay(agent)
                 ? "Shares Agent Relay's hook: both get each request, and the first answer wins."
                 : "Adds one hook to \(HookInstaller.displayPath(agent)) and keeps a backup.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.leading, 48)
            if on, !model.changing.contains(agent) {
                HookSetupView(agent: agent).id(agent)
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

/// The alert as it looks with a prompt, keys along the bottom, and it answers to them: press
/// ⌥↓ and it unfolds, ⌥↩ or ⌥⌫ and it shows what the agent would hear.
private struct PromptPreview: View {
    private let m = Hotkeys.shared.switcher.symbols.replacingOccurrences(of: "⇧", with: "")
    @State private var open = false
    @State private var answer: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let icon = Agent.claude.icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30).padding(.top, 2) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add rate limiting").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 5) {
                        Text("Wants to run").foregroundStyle(.secondary)
                        Text("npm test").font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    }
                    .font(.system(size: 12))
                    if open {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Run the tests before committing the limiter").font(.system(size: 12, weight: .medium))
                            Text("in ~/work/api").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(answer == nil ? Color.orange : .secondary).frame(width: 7, height: 7)
                    Text(answer == nil ? "Needs you" : "Working").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(answer == nil ? Color.orange : .secondary)
                }
            }
            Group {
                if let answer {
                    Label(answer, systemImage: answer == "Allowed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(answer == "Allowed" ? Color.green : .secondary)
                } else {
                    HStack(spacing: 18) {
                        KeyHintView(keys: [m + "↩"], action: "Allow")
                        KeyHintView(keys: [m + "⌫"], action: "Deny")
                        KeyHintView(keys: [m + (open ? "↑" : "↓")], action: open ? "Less" : "Details")
                    }
                }
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Color.orange.opacity(answer == nil ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: open)
        .animation(.easeOut(duration: 0.2), value: answer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example alert: Claude wants to run npm test. Try \(m)Return to allow, \(m)Delete to deny, \(m)Down Arrow for the details.")
        .onAppear(perform: listen)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    /// The tour window has focus, so its own key events will do; nothing global.
    private func listen() {
        guard monitor == nil else { return }
        let modifiers = Hotkeys.shared.switcher.flags.subtracting(.shift)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection([.control, .option, .command]) == modifiers else { return e }
            switch Int(e.keyCode) {
            case kVK_Return: settle("Allowed")
            case kVK_Delete: settle("Denied")
            case kVK_DownArrow: if answer == nil { open = true }
            case kVK_UpArrow: open = false
            default: return e
            }
            return nil
        }
    }

    private func settle(_ what: String) {
        guard answer == nil else { return }
        answer = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { answer = nil; open = false }
    }
}

/// A key as a keycap, then what it does: the same look as the alert's key line.
struct KeyHintView: View {
    let keys: [String]
    let action: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 22, minHeight: 18)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4.5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            }
            Text(action).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

private struct NotifyPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var keys = Hotkeys.shared

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
                Divider().padding(.leading, 62)
                HStack(spacing: 14) {
                    icon("arrow.down.circle.fill", .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Updates").font(.system(size: 14, weight: .semibold))
                        Text("Tells you when a new version is out. Asks GitHub once a day, nothing else.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.checkUpdates).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Tell me about updates")
                }
                .padding(14)
            }
            .frame(width: 460)
            if !model.answerable.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(keys.conflicts.isEmpty ? "Switching and search are available" : "Shortcuts need attention",
                          systemImage: keys.conflicts.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.callout.weight(.semibold))
                    if !keys.conflicts.isEmpty {
                        Button("Choose free shortcuts", action: model.revisitShortcuts)
                    }
                    ForEach(model.answerable, id: \.self) { agent in
                        let on = model.hooks[agent] == true
                        let verified = on && HookSetup.shared.check(agent).phase() == .verified
                        Text("\(agent == .claude ? "Claude Code" : agent.name) answering: \(verified ? "verified" : (on ? "check still pending" : "off"))")
                            .font(.caption).foregroundStyle(verified ? Color.secondary : Color.orange)
                    }
                    if !model.pendingAnswering.isEmpty || model.answerable.contains(where: { model.hooks[$0] != true }) {
                        Button("Finish answering setup", action: model.revisitAnswering)
                    }
                }
                .frame(width: 436, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
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
    /// Per bundle id, so a test build (dev.muster.e2e) never answers the real app's hand-off.
    static let reopen = Notification.Name((Bundle.main.bundleIdentifier ?? "dev.muster.app") + ".reopen")

    /// Another Muster is already running: hand over to it and quit. Unless it started before
    /// this copy was installed, which means it's the version this one replaces (a drag-and-drop
    /// update, `brew upgrade`, or a move from the disk image): then it quits and this one stays.
    static func handOffIfRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
        guard !others.isEmpty else { return false }
        let installed = installedAt()
        if others.allSatisfy({ ($0.launchDate ?? .distantPast) < installed }) {
            others.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            return false
        }
        DistributedNotificationCenter.default().postNotificationName(reopen, object: nil, userInfo: nil, deliverImmediately: true)
        return true
    }

    /// When this copy's executable arrived at its path. Copying, Finder's replace and Homebrew
    /// all create a new file, which sets its status-change time even when they keep the old
    /// modification time.
    private static func installedAt() -> Date {
        guard let exe = Bundle.main.executablePath else { return .distantPast }
        var st = Darwin.stat()
        guard stat(exe, &st) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec) + TimeInterval(st.st_ctimespec.tv_nsec) / 1e9)
    }

    /// The disk image this copy came from, so it can be ejected once Muster is installed.
    private static func diskImage(of path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return "/Volumes/" + parts[2] }
        // A translocated copy hides its volume: look for a mounted Muster with the same id.
        let fm = FileManager.default
        for volume in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let app = "/Volumes/\(volume)/Muster.app"
            if Bundle(path: app)?.bundleIdentifier == Bundle.main.bundleIdentifier { return "/Volumes/" + volume }
        }
        return nil
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

        // Once this copy quits: open the installed one, and eject the disk image it came from.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"; " +
                              "if [ -n \"$1\" ]; then /bin/sleep 1; /usr/bin/hdiutil detach -quiet \"$1\"; fi",
                              dest.path, (translocated || mounted) ? diskImage(of: path) ?? "" : ""]
        try? relaunch.run()
        return true
    }
}


/// A native preview only in the isolated e2e build. It registers no global keys
/// and cannot open or edit the user's agents.
enum OnboardingPreview {
    private static var window: NSWindow?
    static func show(step: OnboardingModel.Step, dark: Bool) -> Bool {
        guard E2E.on, ProcessInfo.processInfo.environment["MUSTER_ONBOARDING_PREVIEW"] == "1" else { return false }
        let model = OnboardingModel(startAt: step)
        model.refresh()
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Muster onboarding preview"
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = NSHostingView(rootView: OnboardingView(model: model))
        model.finish = { [weak w] in HookSetup.shared.stopChecking(); w?.close() }
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        return true
    }
}
