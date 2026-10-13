import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global key combination: a virtual key code plus Carbon modifier flags, with
/// the label shown in Settings captured when it was recorded.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let switcherDefault = Shortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), key: "Tab")
    static let searchDefault = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey), key: "Space")
    static let switcherAlternative = Shortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | controlKey), key: "Tab")

    var symbols: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var display: String { symbols + key }

    /// The held modifiers, for knowing when the switcher's keys are let go.
    var flags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// From a key press while recording; nil unless ⌃, ⌥ or ⌘ is held.
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !f.intersection([.control, .option, .command]).isEmpty else { return nil }
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        let names: [Int: String] = [kVK_Tab: "Tab", kVK_Space: "Space", kVK_Escape: "Esc", kVK_Return: "Return",
                                    kVK_ANSI_Grave: "`", kVK_Delete: "Delete", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→"]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(m), key: key)
    }
}

/// Registers the global shortcuts through Carbon hot keys, which need no
/// Accessibility permission, and reports any another app already owns.
final class Hotkeys: ObservableObject {
    enum Action: UInt32 { case next = 1, previous, up, down, cancel, search }

    static let shared = Hotkeys()

    @Published private(set) var switcher: Shortcut
    @Published private(set) var search: Shortcut
    /// Shortcuts macOS refused because something else registered them first.
    @Published private(set) var conflicts: Set<String> = []

    /// The keys a panel needs while it's up, on top of the switcher and search shortcuts.
    /// Each is held only while a panel asks for it: held all the time, they'd take Move Line
    /// Up and Down, Delete Word, a newline in Claude Code and, on many keyboard layouts,
    /// brackets from every other app.
    struct PanelKeys: Equatable {
        var arrows = false    // ↑ ↓
        var escape = false    // Esc
        var confirm = false   // Return
        var always = false    // ⇧Return
        var deny = false      // Delete
        var digits = 0        // 1 to `digits`

        static let all = PanelKeys(arrows: true, escape: true, confirm: true, always: true, deny: true, digits: 9)

        func union(_ o: PanelKeys) -> PanelKeys {
            PanelKeys(arrows: arrows || o.arrows, escape: escape || o.escape, confirm: confirm || o.confirm,
                      always: always || o.always, deny: deny || o.deny, digits: max(digits, o.digits))
        }
    }

    private(set) var handler: ((Action) -> Void)?
    var onAnswer: ((Answer) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var panelRefs: [EventHotKeyRef] = []
    private var owners: [String: PanelKeys] = [:]
    /// What the panels ask for together; registered unless this is a headless e2e run.
    private(set) var held = PanelKeys()
    /// When one of these shortcuts last fired, so the alert can tell its own keys from typing.
    private(set) var lastPress = Date.distantPast
    private var installed = false

    private init() {
        switcher = Self.load("shortcut.switcher") ?? .switcherDefault
        search = Self.load("shortcut.search") ?? .searchDefault
    }

    func install(_ handler: @escaping (Action) -> Void) {
        self.handler = handler
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                Hotkeys.shared.lastPress = Date()
                if id.id >= 10 { Hotkeys.shared.answerKey(id.id) } else if let action = Action(rawValue: id.id) { Hotkeys.shared.handler?(action) }
                return noErr
            }, 1, &spec, nil, nil)
        }
        register()
    }

    func set(switcher s: Shortcut) {
        switcher = s
        save(s, "shortcut.switcher")
        register()
        registerPanelKeys()
    }

    func set(search s: Shortcut) {
        search = s
        save(s, "shortcut.search")
        register()
    }

    /// Ask for keys while a panel is up, with the switcher's modifiers; nil gives them back.
    func hold(_ keys: PanelKeys?, owner: String) {
        owners[owner] = keys
        let want = owners.values.reduce(PanelKeys()) { $0.union($1) }
        guard want != held else { return }
        held = want
        registerPanelKeys()
    }

    /// The held keys as they read, for e2e runs.
    var heldNames: [String] {
        let m = switcher.symbols.replacingOccurrences(of: "⇧", with: "")
        var names: [String] = []
        if held.arrows { names += [m + "↑", m + "↓"] }
        if held.escape { names.append(m + "Esc") }
        if held.confirm { names.append(m + "↩") }
        if held.always { names.append("⇧" + m + "↩") }
        if held.deny { names.append(m + "⌫") }
        names += (0..<held.digits).map { m + String($0 + 1) }
        return names
    }

    private func registerPanelKeys() {
        panelRefs.forEach { UnregisterEventHotKey($0) }
        panelRefs.removeAll()
        guard E2E.showsUI else { return }
        let m = switcher.modifiers
        var keys: [(UInt32, Int, UInt32)] = []
        if held.arrows { keys += [(Action.up.rawValue, kVK_UpArrow, m), (Action.down.rawValue, kVK_DownArrow, m)] }
        if held.escape { keys.append((Action.cancel.rawValue, kVK_Escape, m)) }
        if held.confirm { keys.append((10, kVK_Return, m)) }
        if held.always { keys.append((11, kVK_Return, m | UInt32(shiftKey))) }
        if held.deny { keys.append((12, kVK_Delete, m)) }
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, d) in digits.prefix(held.digits).enumerated() { keys.append((20 + UInt32(i), d, m)) }
        for (code, key, mods) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D535452), id: code)
            if RegisterEventHotKey(UInt32(key), mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { panelRefs.append(ref) }
        }
    }

    fileprivate func answerKey(_ code: UInt32) {
        switch code {
        case 10: onAnswer?(.allow)
        case 11: onAnswer?(.alwaysAllow)
        case 12: onAnswer?(.deny)
        default: onAnswer?(.option(Int(code) - 20))
        }
    }

    /// While recording a new shortcut, the old ones must not swallow the keys.
    func suspend() { unregister() }
    func resume() { register() }

    private func register() {
        unregister()
        guard E2E.showsUI else { return }   // headless e2e runs leave your keys alone
        var failed: Set<String> = []
        let m = switcher.modifiers
        if !add(.next, switcher.keyCode, m) { failed.insert("switcher") }
        _ = add(.previous, switcher.keyCode, m | UInt32(shiftKey))
        if !add(.search, search.keyCode, search.modifiers) { failed.insert("search") }
        conflicts = failed
    }

    private func add(_ action: Action, _ key: UInt32, _ modifiers: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4D535452), id: action.rawValue)   // 'MSTR'
        let status = RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
        return status == noErr
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private static func load(_ key: String) -> Shortcut? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private func save(_ s: Shortcut, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key)
    }
}

/// Click, then press the new combination. Esc cancels.
struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let conflict: Bool
    let onChange: (Shortcut) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            if conflict && !recording {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Another app already uses \(shortcut.display). Choose a different shortcut.")
            }
            Button(action: toggle) {
                Text(recording ? "Press keys…" : shortcut.display)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 76)
            }
            .buttonStyle(.bordered)
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        Hotkeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape), e.modifierFlags.intersection([.control, .option, .command]).isEmpty {
                stop()
                return nil
            }
            if let s = Shortcut(event: e) {
                stop()
                onChange(s)
                return nil
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { Hotkeys.shared.resume() }
        recording = false
    }
}
