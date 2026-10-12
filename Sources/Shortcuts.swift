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

    private var handler: ((Action) -> Void)?
    var onAnswer: ((Answer) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var answerRefs: [EventHotKeyRef] = []
    private var answerOwners: Set<String> = []
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
        if !answerOwners.isEmpty { registerAnswerKeys() }
    }

    func set(search s: Shortcut) {
        search = s
        save(s, "shortcut.search")
        register()
    }

    /// Return / ⇧Return / Delete / 1–9 with the switcher's modifiers answer a
    /// prompt, registered only while the switcher or the alert shows one.
    func answerKeys(_ on: Bool, owner: String) {
        let before = !answerOwners.isEmpty
        if on { answerOwners.insert(owner) } else { answerOwners.remove(owner) }
        if before != !answerOwners.isEmpty { registerAnswerKeys() }
    }

    private func registerAnswerKeys() {
        answerRefs.forEach { UnregisterEventHotKey($0) }
        answerRefs.removeAll()
        guard !answerOwners.isEmpty else { return }
        let m = switcher.modifiers
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        var keys: [(UInt32, UInt32, UInt32)] = [(10, UInt32(kVK_Return), m), (11, UInt32(kVK_Return), m | UInt32(shiftKey)),
                                                (12, UInt32(kVK_Delete), m)]
        for (i, d) in digits.enumerated() { keys.append((20 + UInt32(i), UInt32(d), m)) }
        for (code, key, mods) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D535452), id: code)
            if RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref { answerRefs.append(ref) }
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
        var failed: Set<String> = []
        let m = switcher.modifiers
        if !add(.next, switcher.keyCode, m) { failed.insert("switcher") }
        _ = add(.previous, switcher.keyCode, m | UInt32(shiftKey))
        _ = add(.up, UInt32(kVK_UpArrow), m)
        _ = add(.down, UInt32(kVK_DownArrow), m)
        _ = add(.cancel, UInt32(kVK_Escape), m)
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
