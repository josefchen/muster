import Foundation

/// Public API list prices in USD per million tokens, standard tier.
/// Sources, retrieved 2026-10-12:
///   https://docs.anthropic.com/en/docs/about-claude/pricing
///   https://developers.openai.com/api/docs/pricing
/// OpenAI's long-context tier is not applied: its threshold isn't published, so
/// Codex costs are a floor. Override or add models in
/// ~/Library/Application Support/Muster/pricing.json (same shape as `builtIn`).
struct Price: Codable {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double
}

enum Pricing {
    static let retrieved = "2026-10-12"

    static let builtIn: [String: Price] = [
        // Anthropic: input, output, 5m cache write, 1h cache write, cache read
        "claude-fable-5-1": Price(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25),
        "claude-fable-5": Price(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1),
        "claude-mythos-5-1": Price(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25),
        "claude-mythos-5": Price(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1),
        "claude-opus-5-5": Price(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2),
        "claude-opus-5": Price(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
        "claude-opus-4-8": Price(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
        "claude-opus-4-7": Price(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
        "claude-opus-4-6": Price(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
        "claude-opus-4-5": Price(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5),
        "claude-opus-4-1": Price(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5),
        "claude-opus-4": Price(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.1),
        "claude-sonnet-5": Price(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2),
        "claude-sonnet-4-6": Price(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3),
        "claude-sonnet-4-5": Price(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3),
        "claude-sonnet-4": Price(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3),
        "claude-haiku-4-5": Price(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1),
        "claude-haiku-3-5": Price(input: 0.8, output: 4, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08),
        // OpenAI: input, output, cache write, cache write, cached input (short context)
        "gpt-6-astra": Price(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 12.5, cacheRead: 1),
        "gpt-6.1-sol": Price(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 2.5, cacheRead: 0.1),
        "gpt-6-luna": Price(input: 0.1, output: 0.5, cacheWrite5m: 0.125, cacheWrite1h: 0.125, cacheRead: 0.01),
        "gpt-5.6-sol": Price(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 5, cacheRead: 0.4),
        "gpt-5.3-codex": Price(input: 1.75, output: 14, cacheWrite5m: 1.75, cacheWrite1h: 1.75, cacheRead: 0.175),
    ]

    static let table: [String: Price] = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Muster/pricing.json")
        guard let data = try? Data(contentsOf: url),
              let custom = try? JSONDecoder().decode([String: Price].self, from: data) else { return builtIn }
        return builtIn.merging(custom) { _, mine in mine }
    }()

    /// Longest known prefix, so dated ids (claude-haiku-4-5-20251001) resolve.
    static func price(for model: String) -> Price? {
        if let p = table[model] { return p }
        return table.keys.filter { model.hasPrefix($0 + "-") }.max { $0.count < $1.count }.flatMap { table[$0] }
    }

    static func cost(_ u: Usage, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(u.input) * p.input + Double(u.output) * p.output + Double(u.cacheWrite5m) * p.cacheWrite5m
                + Double(u.cacheWrite1h) * p.cacheWrite1h + Double(u.cacheRead) * p.cacheRead) / 1_000_000
    }
}
