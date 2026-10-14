import Foundation

// End-to-end tests for Muster: the real app against a fixture home, driven the way
// the agents and you would. Built and run by scripts/e2e.sh:
//
//   driver headless --app <bundle> [--label <arch>]
//   driver soak --app <bundle> [--minutes 10]
//   driver ui --app <bundle> [--baselines <dir>]

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}

guard let bundle = option("--app"), FileManager.default.fileExists(atPath: bundle) else {
    print("usage: driver headless|soak|ui --app <MusterE2E.app> [--label arch] [--minutes n] [--baselines dir]")
    exit(64)
}

// Room for the abuse cases' hundreds of sockets. The app itself keeps launchd's 256.
var limit = rlimit()
getrlimit(RLIMIT_NOFILE, &limit)
limit.rlim_cur = min(8192, limit.rlim_max)
setrlimit(RLIMIT_NOFILE, &limit)

// However the run ends: no app left running, no fixture left behind, no e2e settings kept.
atexit {
    Keys.releaseAll()
    App.stopAll()
    Fixture.cleanupAll()
    wipeDefaults()
}
signal(SIGINT) { _ in exit(130) }
signal(SIGTERM) { _ in exit(143) }

func summary(_ started: Date, _ label: String) -> Never {
    let elapsed = Int(Date().timeIntervalSince(started).rounded())
    print("\n\(passed) passed, \(failures) failed in \(elapsed / 60) min \(elapsed % 60) s\(label.isEmpty ? "" : " (\(label))")")
    for name in failedChecks { print("  ✗ \(name)") }
    exit(failures == 0 ? 0 : 1)
}

/// The app's own words when it refuses e2e mode or crashes; never paths or titles.
func appMessages(_ fx: Fixture) -> [String] {
    ((try? String(contentsOfFile: fx.appLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("Muster") }
}

func runHeadless(bundle: String, label: String) -> Never {
    let started = Date()
    print("Muster e2e: headless\(label.isEmpty ? "" : ", \(label)")")
    wipeDefaults()
    let fx = Fixture()
    let seeded = Headless.seed(fx)
    let app = App(bundle: bundle, fixture: fx)
    // A first launch can be slow while macOS scans the new binary, on Intel Macs especially.
    guard app.launch(timeout: 60) else {
        appMessages(fx).forEach { note($0) }
        fx.cleanup()
        fatal("the app didn't start (\(app.exitDescription))")
    }
    Headless(app: app, fx: fx, seeded: seeded).run()
    app.stop()
    wipeDefaults()
    fx.cleanup()
    summary(started, label)
}

switch arguments.first {
case "headless": runHeadless(bundle: bundle, label: option("--label") ?? "")
case "soak": runSoak(bundle: bundle, minutes: Double(option("--minutes") ?? "10") ?? 10)
case "ui": runUI(bundle: bundle, baselines: option("--baselines"))
default:
    print("unknown mode")
    exit(64)
}
