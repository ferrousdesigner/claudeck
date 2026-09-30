import Foundation

/// API list prices in USD per million tokens (Anthropic first-party rates, Sept 2026).
/// Pro/Max subscribers aren't billed per token, so for them this is an "API-equivalent" value.
struct ModelPrice: Hashable {
    var input: Double
    var output: Double
    var cacheRead: Double
    /// 5-minute cache writes cost 1.25× input, 1-hour cache writes 2× input.
    var cacheWrite5m: Double { input * 1.25 }
    var cacheWrite1h: Double { input * 2 }
}

enum Pricing {
    /// Matched against the model id by prefix/substring, most specific first.
    static let table: [(match: String, price: ModelPrice)] = [
        ("fable", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("mythos", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("opus", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("sonnet", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("haiku", ModelPrice(input: 1, output: 5, cacheRead: 0.10)),
    ]
    static let fallback = ModelPrice(input: 5, output: 25, cacheRead: 0.50)

    static func price(for model: String) -> ModelPrice {
        let m = model.lowercased()
        return table.first { m.contains($0.match) }?.price ?? fallback
    }

    static func cost(_ t: TokenUsage, model: String) -> Double {
        let p = price(for: model)
        let write1h = min(t.cacheCreate1h, t.cacheCreate)
        let write5m = t.cacheCreate - write1h
        return (Double(t.input) * p.input
                + Double(t.output) * p.output
                + Double(write5m) * p.cacheWrite5m
                + Double(write1h) * p.cacheWrite1h
                + Double(t.cacheRead) * p.cacheRead) / 1_000_000
    }

    static func cost(byModel: [String: TokenUsage]) -> Double {
        byModel.reduce(0) { $0 + cost($1.value, model: $1.key) }
    }
}

extension Fmt {
    static func usd(_ v: Double) -> String {
        if v >= 1000 { return String(format: "$%.0f", v) }
        if v >= 100 { return String(format: "$%.1f", v) }
        if v >= 0.01 || v == 0 { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }
}

/// Spending limits the user sets in Settings; alerts fire at 80% and 100%.
enum Budget {
    static var daily: Double { UserDefaults.standard.double(forKey: "budgetDaily") }
    static var weekly: Double { UserDefaults.standard.double(forKey: "budgetWeekly") }
    static var monthly: Double { UserDefaults.standard.double(forKey: "budgetMonthly") }
}
