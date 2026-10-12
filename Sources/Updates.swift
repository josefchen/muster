import AppKit

/// Asks GitHub for the latest release, only when you click Check for Updates or
/// turn on the daily check. Nothing else ever leaves the Mac.
enum Updates {
    private static let latest = URL(string: "https://api.github.com/repos/josefchen/muster/releases/latest")!
    private static let d = UserDefaults.standard
    private static var timer: Timer?

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static var automatic: Bool {
        get { d.bool(forKey: "updates.auto") }
        set { d.set(newValue, forKey: "updates.auto"); schedule() }
    }

    static func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic, !Store.demo else { return }
        let due = { Date().timeIntervalSince1970 - d.double(forKey: "updates.last") > 86_400 }
        if due() { check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in if due() { check(manual: false) } }
    }

    static func check(manual: Bool) {
        var request = URLRequest(url: latest, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Muster/\(version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let release = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            DispatchQueue.main.async {
                d.set(Date().timeIntervalSince1970, forKey: "updates.last")
                guard (response as? HTTPURLResponse)?.statusCode == 200, let release,
                      let tag = release["tag_name"] as? String else {
                    if manual { tell("Couldn't check for updates", "GitHub didn't answer. Try again in a moment.") }
                    return
                }
                let available = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard newer(available, than: version) else {
                    if manual { tell("You're up to date", "Muster \(version) is the latest version.") }
                    return
                }
                guard manual || d.string(forKey: "updates.skipped") != available else { return }
                offer(available, notes: release["body"] as? String ?? "")
            }
        }.resume()
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func offer(_ available: String, notes: String) {
        let alert = NSAlert()
        alert.messageText = "Muster \(available) is available"
        let summary = notes.split(separator: "\n").prefix(6).joined(separator: "\n")
        alert.informativeText = (summary.isEmpty ? "" : summary + "\n\n")
            + "You have \(version). Installed with Homebrew? Run brew upgrade --cask muster."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/josefchen/muster/releases/latest/download/Muster.dmg")!)
        case .alertThirdButtonReturn:
            d.set(available, forKey: "updates.skipped")
        default:
            break
        }
    }

    private static func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
