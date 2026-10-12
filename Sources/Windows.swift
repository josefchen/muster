import AppKit
import SwiftUI
import UserNotifications

// Settings, in SwiftUI's native grouped form so it looks like System Settings.
// Built only when opened; the always-on paths (menu bar, switcher, deck) stay
// plain AppKit.

final class Windows {
    private var settingsWindow: NSWindow?

    func show() {
        let w = settingsWindow ?? window("Muster Settings", SettingsView(), size: NSSize(width: 460, height: 560))
        settingsWindow = w
        present(w)
    }

    private func window<V: View>(_ title: String, _ view: V, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject private var keys = Hotkeys.shared
    @State private var launch = Settings.launchAtLogin
    @State private var needsYou = Settings.notifyNeedsYou
    @State private var done = Settings.notifyDone
    @State private var alert = Attention.enabled
    @State private var autoUpdate = Updates.automatic
    @State private var costDisplay = Settings.costDisplay
    @State private var week = Stats.week()
    @State private var agents = Settings.enabledAgents
    @State private var sources = Store.shared.sources
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var answering: [Agent: Bool] = [:]
    @State private var answerError: String?
    @State private var broken: [String] = []
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launch).onChange(of: launch) { _, v in Settings.launchAtLogin = v }
            }
            Section("Shortcuts") {
                LabeledContent("Switch between sessions") {
                    ShortcutRecorder(shortcut: keys.switcher, conflict: keys.conflicts.contains("switcher")) { keys.set(switcher: $0) }
                }
                LabeledContent("Search all sessions") {
                    ShortcutRecorder(shortcut: keys.search, conflict: keys.conflicts.contains("search")) { keys.set(search: $0) }
                }
                if !keys.conflicts.isEmpty {
                    Text("Another app already uses a shortcut marked ⚠︎. Click it and press a new combination.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(Agent.allCases, id: \.self) { agent in
                    Toggle(isOn: Binding(get: { agents.contains(agent) }, set: { on in
                        if on { agents.insert(agent) } else { agents.remove(agent) }
                        Settings.setEnabled(agent, on)
                        Store.shared.rescan()
                    })) {
                        HStack(spacing: 10) {
                            if let icon = agent.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.name)
                                Text(sourceText(agent)).font(.caption).foregroundStyle(sourceColour(agent))
                            }
                        }
                    }
                }
            } header: {
                Text("Watch")
            }
            Section {
                ForEach([Agent.claude, Agent.codex], id: \.self) { agent in
                    Toggle(isOn: Binding(get: { answering[agent] ?? false }, set: { on in
                        do {
                            try on ? HookInstaller.install(agent) : HookInstaller.uninstall(agent)
                            answerError = nil
                        } catch { answerError = error.localizedDescription }
                        answering[agent] = HookInstaller.isInstalled(agent)
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent == .claude ? "Claude Code" : "Codex")
                            Text(agent == .claude ? "Permissions, questions and plans" : "Approvals. Trust the hook once in Codex with /hooks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let answerError { Text(answerError).font(.callout).foregroundStyle(.orange) }
                if !broken.isEmpty {
                    HStack {
                        Text("\(broken.joined(separator: ", ")) is gone, but its Claude hooks still run and fail.")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("Remove") {
                            do { try HookInstaller.removeBrokenClaudeHooks(); answerError = nil }
                            catch { answerError = error.localizedDescription }
                            refresh()
                        }
                    }
                }
            } header: {
                Text("Answer prompts from Muster")
            } footer: {
                Text("Adds a hook to the agent's own settings, keeping a backup; turning it off removes exactly that. "
                     + "If Muster isn't running, the agent asks as usual. Cursor's hooks can't step aside for prompts it would "
                     + "auto-approve, so Cursor prompts open in Cursor.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $alert) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show an alert at the top of the screen")
                        Text("Stays until you answer or dismiss it. Works in Focus modes and with a full menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: alert) { _, v in
                    Attention.enabled = v
                    NotificationCenter.default.post(name: Attention.changed, object: nil)
                }
            } header: {
                Text("When an agent needs you")
            }
            Section("Notify me when a session") {
                Toggle("Needs me or hits an error", isOn: $needsYou).onChange(of: needsYou) { _, v in Settings.notifyNeedsYou = v }
                Toggle("Finishes", isOn: $done).onChange(of: done) { _, v in Settings.notifyDone = v }
                if notifications == .denied || notifications == .notDetermined {
                    HStack {
                        Text(notifications == .denied ? "Notifications are turned off for Muster." : "Muster hasn't been allowed to notify you yet.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if notifications == .denied {
                            Button("Open Settings", action: Notifier.openSystemSettings)
                        } else {
                            Button("Allow…") { Notifier.requestAuthorization(refresh) }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Version") { Text(Updates.version).foregroundStyle(.secondary) }
                Toggle("Check for updates once a day", isOn: $autoUpdate).onChange(of: autoUpdate) { _, v in Updates.automatic = v }
                Button("Check for Updates…") { Updates.check(manual: true) }
            } header: {
                Text("Updates")
            } footer: {
                Text("Asks GitHub for the latest release. Nothing else is sent, and nothing at all unless you check.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("This week") {
                    Text(Stats.summary(week)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("What Muster did for you")
            } footer: {
                Text(Stats.assumption + " Counted on this Mac only.").foregroundStyle(.secondary)
            }
            Section {
                Picker("Show on each session", selection: $costDisplay) {
                    Text("Cost and tokens").tag(Settings.CostDisplay.costAndTokens)
                    Text("Tokens only").tag(Settings.CostDisplay.tokens)
                    Text("Nothing").tag(Settings.CostDisplay.hidden)
                }
                .onChange(of: costDisplay) { _, v in
                    Settings.costDisplay = v
                    Store.shared.refreshPrompts()
                }
                LabeledContent("Prices from") { Text("Anthropic and OpenAI, \(Pricing.retrieved)").foregroundStyle(.secondary) }
                Button("Use my own prices…") { Self.revealPricingFile() }
            } header: {
                Text("API cost estimate")
            } footer: {
                Text("What each session's tokens would cost at public API list prices. It is not what your subscription bills.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        sources = Store.shared.sources
        answering = [.claude: HookInstaller.isInstalled(.claude), .codex: HookInstaller.isInstalled(.codex)]
        broken = HookInstaller.brokenClaudeHooks()
        week = Stats.week()
        Notifier.status { notifications = $0 }
    }

    private func sourceText(_ agent: Agent) -> String {
        guard agents.contains(agent) else { return "Not watched" }
        return sources[agent]?.summary ?? "Looking…"
    }

    private func sourceColour(_ agent: Agent) -> Color {
        if case .unreadable = sources[agent] { return .orange }
        return .secondary
    }

    /// Creates ~/Library/Application Support/Muster/pricing.json from the built-in table and shows it in Finder.
    static func revealPricingFile() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Muster")
        let file = dir.appendingPathComponent("pricing.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(Pricing.builtIn).write(to: file)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
