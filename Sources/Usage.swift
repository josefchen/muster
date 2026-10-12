import AppKit
import SwiftUI

// The Usage window: what your agents used over the last 30 days, at API list
// prices or in tokens. Computed on this Mac from the files the agents already
// write, only while the window is open; closing it drops everything.

final class UsageModel: ObservableObject {
    enum Phase {
        case starting                // the first moments, so a cached scan doesn't flash a spinner
        case loading(Double)
        case ready(UsageHistory)
    }

    @Published private(set) var phase: Phase = .starting
    private let stopped = Flag()
    /// One scan at a time: reopening the window while a cancelled scan finishes
    /// would otherwise write the cache twice.
    private static let queue = DispatchQueue(label: "muster.usage", qos: .utility)

    func start() {
        if Store.demo { phase = .ready(.sample()); return }
        let stopped = self.stopped
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if case .starting = self?.phase { self?.phase = .loading(0) }
        }
        Self.queue.async { [weak self] in
            let result = autoreleasepool {
                History().scan(progress: { p in
                    DispatchQueue.main.async { if case .loading = self?.phase { self?.phase = .loading(p) } }
                }, cancelled: { stopped.isSet })
            }
            malloc_zone_pressure_relief(nil, 0)
            guard let result else { return }
            DispatchQueue.main.async { self?.phase = .ready(result) }
        }
    }

    func stop() { stopped.set() }

    private final class Flag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

struct UsageView: View {
    enum Metric { case cost, tokens }

    @ObservedObject var model: UsageModel
    @State private var metric: Metric = Settings.costDisplay == .costAndTokens ? .cost : .tokens
    private let week = Store.demo ? Stats.Week(answered: 48, jumps: 132) : Stats.week()
    private static let rows = 5

    var body: some View {
        Form {
            Section {
                LabeledContent("This week") {
                    Text(Stats.summary(week)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("What Muster did for you")
            } footer: {
                Text(Stats.assumption).foregroundStyle(.secondary)
            }
            switch model.phase {
            case .starting:
                EmptyView()
            case .loading(let progress):
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reading your agents' transcripts on this Mac…")
                        ProgressView(value: progress)
                        Text("The first time takes a few seconds. After that, only new lines are read.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Last 30 days")
                } footer: {
                    cursorNote
                }
            case .ready(let history) where history.tokens == 0:
                Section {
                    Text("No Claude or Codex usage in the last 30 days.").foregroundStyle(.secondary)
                } header: {
                    Text("Last 30 days")
                } footer: {
                    cursorNote
                }
            case .ready(let history):
                chart(history)
                table("Top models", history.models)
                table("Top projects", history.projects)
            }
        }
        .formStyle(.grouped)
    }

    private var cursorNote: some View {
        Text("Cursor doesn't record token counts on disk, so it isn't included.").foregroundStyle(.secondary)
    }

    private func chart(_ h: UsageHistory) -> some View {
        Section {
            Picker("Show", selection: $metric) {
                Text("≈ Cost").tag(Metric.cost)
                Text("Tokens").tag(Metric.tokens)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 10) {
                Text(metric == .cost ? "≈ \(money(h.cost)) at API rates" : "\(compact(h.tokens)) tokens")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                DailyBars(days: h.days, metric: metric).frame(height: 200)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Last 30 days")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cost is an estimate at public API list prices, not what a subscription bills."
                     + (h.unpriced ? " Models without a known price are counted in tokens only." : ""))
                cursorNote
            }
            .foregroundStyle(.secondary)
        }
    }

    private func table(_ title: String, _ rows: [UsageHistory.Row]) -> some View {
        let sorted = metric == .cost ? rows.sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.tokens > $1.tokens } : rows
        return Section {
            ForEach(sorted.prefix(Self.rows)) { row in
                HStack(spacing: 8) {
                    Circle().fill(row.agent?.chartColour ?? .clear).frame(width: 7, height: 7)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(compact(row.tokens)).frame(width: 64, alignment: .trailing)
                    Text(row.cost > 0 ? "≈ \(money(row.cost))" : "No price").frame(width: 90, alignment: .trailing)
                }
                .monospacedDigit()
                .foregroundStyle(.primary)
            }
        } header: {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                Text("Tokens").frame(width: 64, alignment: .trailing)
                Text("At API rates").frame(width: 90, alignment: .trailing)
            }
        }
    }
}

/// Stacked daily bars drawn from plain shapes. Swift Charts allocates about 200 MB
/// of GPU memory whenever it draws, even into an image, which this app can't carry.
private struct DailyBars: View {
    let days: [UsageHistory.Day]
    let metric: UsageView.Metric
    private static let agents = [Agent.claude, Agent.codex]
    private static let axis: CGFloat = 46
    private static let dates: CGFloat = 18

    var body: some View {
        let ticks = Self.ticks(days.map { d in Self.agents.reduce(0) { $0 + value(d, $1) } }.max() ?? 0)
        let top = ticks.last ?? 1
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(Self.agents, id: \.self) { a in
                    HStack(spacing: 4) {
                        Circle().fill(a.chartColour).frame(width: 7, height: 7)
                        Text(a.name)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GeometryReader { g in
                let width = g.size.width - Self.axis, height = g.size.height - Self.dates
                let slot = width / CGFloat(max(1, days.count))
                let bar = max(2, slot * 0.68)
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { t in
                        let y = height * (1 - t / top)
                        Rectangle().fill(.quaternary).frame(width: width, height: 1).offset(y: y)
                        Text(label(t)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            .offset(x: width + 6, y: y - 7)
                    }
                    ForEach(days.indices, id: \.self) { i in
                        let d = days[i]
                        VStack(spacing: 0) {
                            ForEach(Self.agents.reversed(), id: \.self) { a in
                                Rectangle().fill(a.chartColour).frame(height: height * value(d, a) / top)
                            }
                        }
                        .frame(width: bar)
                        .offset(x: CGFloat(i) * slot + (slot - bar) / 2, y: height * (1 - Self.agents.reduce(0) { $0 + value(d, $1) } / top))
                        .help(tooltip(d))
                    }
                    // Weekly, leaving out the last few days, where the label would run past the plot.
                    ForEach(days.indices.filter { $0 % 7 == 0 && $0 < days.count - 4 }, id: \.self) { i in
                        Text(days[i].start.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                            .offset(x: CGFloat(i) * slot + (slot - bar) / 2, y: height + 4)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric == .cost ? "Daily cost at API rates, last 30 days" : "Daily tokens, last 30 days")
    }

    private func value(_ d: UsageHistory.Day, _ a: Agent) -> Double {
        metric == .cost ? d.cost[a] ?? 0 : Double(d.tokens[a] ?? 0)
    }

    private func label(_ v: Double) -> String { metric == .cost ? money(v) : compact(Int(v)) }

    private func tooltip(_ d: UsageHistory.Day) -> String {
        let parts = Self.agents.map { a in
            "\(a.name) " + (metric == .cost ? "≈ \(money(d.cost[a] ?? 0))" : compact(d.tokens[a] ?? 0))
        }
        return d.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + "  ·  " + parts.joined(separator: "  ·  ")
    }

    /// 0 up to the first round step at or above `max`, in about four steps.
    static func ticks(_ max: Double) -> [Double] {
        guard max > 0 else { return [0, 1] }
        let raw = max / 4
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        return (0...Int((max / step).rounded(.up))).map { Double($0) * step }
    }
}

private extension Agent {
    var chartColour: Color {
        switch self {
        case .claude: return Color(red: 0xEE / 255, green: 0x8C / 255, blue: 0x33 / 255)
        case .codex: return Color(red: 0x45 / 255, green: 0x85 / 255, blue: 0xFA / 255)
        case .cursor: return Color(nsColor: colour)
        }
    }
}
