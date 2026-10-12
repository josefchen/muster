import AppKit
import SwiftUI
import UserNotifications

// Settings and the first-run welcome, in SwiftUI's native grouped form so they
// look like System Settings. Built only when opened; the always-on paths
// (menu bar, switcher, deck) stay plain AppKit.

final class Windows {
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func show() {
        let w = settingsWindow ?? window("Muster Settings", SettingsView(), size: NSSize(width: 460, height: 560))
        settingsWindow = w
        present(w)
    }

    func welcome() {
        let w = welcomeWindow ?? window("Welcome to Muster", WelcomeView { [weak self] in self?.welcomeWindow?.close() },
                                        size: NSSize(width: 460, height: 520))
        welcomeWindow = w
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
    @State private var agents = Settings.enabledAgents
    @State private var sources = Store.shared.sources
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var answering: [Agent: Bool] = [:]
    @State private var answerError: String?
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
            } header: {
                Text("Answer prompts from Muster")
            } footer: {
                Text("Adds a hook to the agent's own settings, keeping a backup; turning it off removes exactly that. "
                     + "If Muster isn't running, the agent asks as usual. Cursor's hooks can't step aside for prompts it would "
                     + "auto-approve, so Cursor prompts open in Cursor.")
                    .foregroundStyle(.secondary)
            }
            Section("Notify me when a session") {
                Toggle("Needs me or hits an error", isOn: $needsYou).onChange(of: needsYou) { _, v in Settings.notifyNeedsYou = v }
                Toggle("Finishes", isOn: $done).onChange(of: done) { _, v in Settings.notifyDone = v }
                if notifications == .denied || notifications == .notDetermined {
                    HStack {
                        Text(notifications == .denied ? "Notifications are turned off for Muster." : "Muster hasn't been allowed to notify you yet.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }
            Section {
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
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notifications = s.authorizationStatus }
        }
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

private struct WelcomeView: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).padding(.top, 34)
            VStack(spacing: 6) {
                Text("Muster").font(.system(size: 30, weight: .bold))
                Text("Every agent, one glance.").font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "rectangle.stack", title: "Lives in your menu bar",
                        text: "A count appears when a Claude, Codex or Cursor session is waiting on you.")
                Feature(symbol: "command", title: "\(Hotkeys.shared.switcher.display) to switch",
                        text: "Hold \(Hotkeys.shared.switcher.symbols) and tap \(Hotkeys.shared.switcher.key) to walk your sessions. Let go to open one.")
                Feature(symbol: "checkmark.bubble", title: "Answer from anywhere",
                        text: "Allow a command or pick an answer without leaving what you're doing. Turn it on in Settings.")
                Feature(symbol: "magnifyingglass", title: "\(Hotkeys.shared.search.display) to search",
                        text: "Find any session from the last three hours by name or project.")
            }
            .padding(.horizontal, 44)
            Spacer(minLength: 0)
            Button(action: done) { Text("Get Started").frame(width: 200) }
                .controlSize(.large).keyboardShortcut(.defaultAction).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Feature: View {
    let symbol: String, title: String, text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
