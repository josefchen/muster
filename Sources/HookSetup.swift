import AppKit
import Combine
import SwiftUI

/// Main-thread owner of setup evidence. UI polls config only while visible;
/// transcript checks do work only while a request awaits confirmation.
final class HookSetup: ObservableObject {
    static let shared = HookSetup()
    private let defaults: UserDefaults
    private var checks: [Agent: HookVerification] = [:]
    @Published private(set) var revision = 0
    @Published private(set) var codexReview: CodexHookReview = .unavailable
    private var reviewRunning = false
    private var reviewedAt = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for agent in [Agent.claude, .codex] {
            let saved = defaults.data(forKey: key(agent)).flatMap { try? JSONDecoder().decode(HookVerification.Saved.self, from: $0) }
            checks[agent] = HookVerification(saved: saved)
        }
    }

    private func key(_ agent: Agent) -> String { "hookVerification.\(agent.rawValue)" }

    func refresh() {
        for agent in [Agent.claude, .codex] { configure(agent) }
        revision += 1
    }

    private func configure(_ agent: Agent) {
        let digest = HookInstaller.verificationDigest(agent)
        guard checks[agent]?.digest != digest else { return }
        checks[agent, default: HookVerification()].configure(digest)
        if agent == .codex { codexReview = .unavailable; reviewedAt = .distantPast }
        persist(agent)
    }

    /// No model run and no permission changes. Older clients without hooks/list
    /// fall back to the live approval check instead of being called broken.
    func inspectCodex() {
        guard !Store.demo, !E2E.on, !reviewRunning, Date().timeIntervalSince(reviewedAt) >= 15,
              let digest = checks[.codex]?.digest, let command = HookInstaller.codexCommandForReview else { return }
        reviewedAt = Date()
        guard let executable = Self.codexExecutable else { return }
        let path = HookInstaller.codexHooks
        reviewRunning = true
        DispatchQueue.global(qos: .utility).async {
            let result = CodexHookReview.read(executable: executable, hookPath: path, command: command, home: home)
            DispatchQueue.main.async {
                self.reviewRunning = false
                self.configure(.codex)
                guard self.checks[.codex]?.digest == digest else { return }
                self.codexReview = result
                if result.blocksCheck { self.checks[.codex]?.invalidate(); self.persist(.codex) }
                self.revision += 1
            }
        }
    }

    private static var codexExecutable: String? {
        // Prefer the desktop's own version when present; its trust schema can
        // differ from a separately installed CLI.
        var candidates: [String] = []
        for id in Agent.codex.bundleIDs {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path else { continue }
            candidates += [app + "/Contents/Resources/codex", app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
        }
        candidates += [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first {
            let url = URL(fileURLWithPath: $0).resolvingSymlinksInPath()
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    func check(_ agent: Agent) -> HookVerification { checks[agent] ?? HookVerification() }

    var pending: [Agent] {
        [Agent.claude, .codex].filter { HookInstaller.isInstalled($0) && check($0).phase() != .verified }
    }

    func begin(_ agent: Agent) {
        configure(agent)
        checks[agent]?.begin()
        persist(agent)
        revision += 1
    }

    func isGuidedCheck(_ agent: Agent) -> Bool {
        let check = check(agent)
        return check.checkingSince != nil && [.waiting, .received].contains(check.phase())
    }

    func stopChecking() {
        for agent in [Agent.claude, .codex] where checks[agent]?.checkingSince != nil {
            checks[agent]?.invalidate()
            persist(agent)
        }
        Prompts.shared.endGuidedChecks()
        revision += 1
    }

    func received(_ prompt: Prompt) {
        configure(prompt.agent)
        // An old, still-running session can call a hook whose new definition
        // Codex has not trusted yet. Do not certify that changed definition.
        guard prompt.agent != .codex || !codexReview.blocksCheck else { return }
        let baseline = Store.shared.sessions.first { $0.agent == prompt.agent && $0.sid == prompt.sessionID }?.since
        checks[prompt.agent]?.received(id: prompt.id, sessionID: prompt.sessionID, baseline: baseline)
        revision += 1
    }

    func replied(_ prompt: Prompt, success: Bool) {
        configure(prompt.agent)
        checks[prompt.agent]?.replied(id: prompt.id, success: success)
        persist(prompt.agent)
        revision += 1
    }

    func disconnected(_ prompt: Prompt) {
        checks[prompt.agent]?.disconnected(id: prompt.id)
        revision += 1
    }

    func progressed(_ sessions: [Session]) {
        for agent in [Agent.claude, .codex] where check(agent).awaitingProgress() {
            configure(agent)
            let before = checks[agent]?.verifiedAt
            for session in sessions where session.agent == agent {
                checks[agent]?.progressed(sessionID: session.sid, since: session.since,
                                         runningOrDone: session.status == .working || session.status == .done)
            }
            if checks[agent]?.verifiedAt != before { persist(agent); revision += 1 }
        }
    }

    private func persist(_ agent: Agent) {
        if let saved = checks[agent]?.saved, let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: key(agent))
        } else { defaults.removeObject(forKey: key(agent)) }
    }
}

/// The same live status and next action in onboarding and Settings.
struct HookSetupView: View {
    let agent: Agent
    @ObservedObject private var setup = HookSetup.shared
    @State private var copied = false
    @State private var showHelp = false
    @State private var openError: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var phase: HookVerification.Phase { setup.check(agent).phase() }
    private var codex: Bool { agent == .codex }
    private var name: String { codex ? "Codex" : "Claude Code" }
    private var prompt: String {
        "I’m checking Muster’s approval connection. Please request my approval to run `printf 'Muster connection check\\n'` through your normal permission flow. Do not change any files. If this session cannot ask for approval, tell me instead of running it automatically."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: phase == .verified ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(phase == .verified ? Color.green : Color.primary)
                .accessibilityIdentifier("hook-setup-\(agent.rawValue)-\(phase.rawValue)")
            Text(detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if phase != .verified {
                if codex && (phase == .unverified || showHelp) {
                    Text("In Codex: Settings → Hooks → User config → PermissionRequest. Expand the hook, check that its command calls Muster on 127.0.0.1, then enable and trust it. In the CLI, run /hooks.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if phase != .received && phase != .replied {
                    HStack {
                        Button(copied ? "Check prompt copied" : "Copy check prompt") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                            copied = true
                            setup.begin(agent)
                        }
                        .disabled(phase == .notInstalled || (codex && setup.codexReview.blocksCheck))
                        Button("Open \(name)", action: openAgent)
                    }
                    .controlSize(.small)
                    Text("Paste the prompt into a local \(name) session that asks for approval, then return here. Full access or automatic approval may skip the hook; use a session that asks first for this check.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let date = setup.check(agent).verifiedAt {
                Text("Last verified \(date.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                if phase == .verified { Button("Check again") { setup.begin(agent) } }
                Button(showHelp ? "Hide help" : "Troubleshoot") { showHelp.toggle() }
                if codex, showHelp {
                    Button("Copy /hooks") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/hooks", forType: .string)
                    }
                }
            }
            .controlSize(.small)
            if showHelp {
                Text("If nothing arrives: refresh Hooks in Codex or start a new CLI session after enabling it. Check that hooks are enabled in the agent’s settings and that the session runs on this Mac. Remote and cloud sessions may not reach this Mac’s hook. If a command runs without asking, that does not test the hook.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("If a reply was sent but setup stays pending, check the agent’s session. Muster waits for its transcript to resume; it will not assume the reply worked. You can finish this later in Settings.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let openError { Text(openError).font(.caption).foregroundStyle(.orange) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { refresh() }
        .onReceive(tick) { _ in refresh() }
    }

    private var title: String {
        if codex, setup.codexReview.blocksCheck { return "Finish enabling Muster in Codex" }
        switch phase {
        case .notInstalled: return "Hook needs attention"
        case .unverified: return "\(name) answering is not verified"
        case .waiting: return "Waiting for \(name) to ask"
        case .received: return "Request received. Answer it in Muster."
        case .replied: return "Reply sent. Waiting for \(name) to resume."
        case .verified: return "\(name) answering verified"
        case .timedOut: return "The check is still incomplete"
        case .interrupted: return "The request closed before Muster answered"
        case .failed: return "The reply could not be delivered"
        }
    }

    private var detail: String {
        if codex {
            switch setup.codexReview {
            case .disabled: return "Codex reports that hooks or this hook are disabled. Enable Muster in Codex. If config.toml sets hooks = false under [features], enable hooks there too. This status updates while setup is open."
            case .needsTrust: return "Codex found Muster’s hook but has not trusted it. Review and trust it in Codex, then return here for the connection check."
            case .modified: return "Muster’s hook changed since Codex trusted it. Review the updated command in Codex before testing the connection."
            case .missing: return "Codex did not load this Muster hook. Refresh Hooks or start a new CLI session. Check that Codex loads \(HookInstaller.displayPath(.codex))."
            case .enabled where phase == .unverified: return "Codex reports the hook is enabled and trusted. Now complete an approval request to verify the whole connection."
            default: break
            }
        }
        switch phase {
        case .notInstalled: return "The hook is missing, incomplete or disabled. Turn answering off and back on to reinstall it, then enable it in the agent. Your other hooks are kept."
        case .unverified: return "The hook is installed. Complete a real approval request so Muster can check the connection."
        case .waiting: return "Muster is listening. Installing or enabling a hook alone does not complete this check."
        case .received: return "Use the alert or switcher to Allow or Deny the request. Answering in the agent itself does not test Muster’s reply."
        case .replied: return "Muster delivered the answer. Setup completes when the same session’s transcript advances."
        case .verified: return "A real request arrived, Muster sent your answer, and the session resumed. This records the last successful check, not a continuous connection."
        case .timedOut: return "No complete round trip was observed within two minutes. Check the steps below and copy the check prompt to try again. Nothing is approved automatically."
        case .interrupted: return "The agent took the request back or you answered there. Try again and answer from Muster."
        case .failed: return "The agent disconnected before the answer was sent. Try another approval request."
        }
    }

    private func refresh() {
        setup.refresh()
        if codex { setup.inspectCodex() }
    }

    private func openAgent() {
        guard !E2E.on else { return }
        // Codex's desktop now also ships inside ChatGPT; do not assume one bundle ID.
        guard let url = agent.bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            openError = "Open \(name) in your terminal, then paste the check prompt."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { openError = error.map { "Could not open \(name): \($0.localizedDescription)" } }
        }
    }
}
