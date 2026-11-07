import Foundation
import Combine

/// Tracks per-day API usage and estimates cost. Usage is kept per model, since checks and chat may use
/// different ones. The estimate uses first-party list prices and is approximate; the Anthropic Console
/// has the real numbers.
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()
    private let d = UserDefaults.standard

    @Published private(set) var calls = 0
    /// Today's total across models.
    @Published private(set) var usage = APIUsage()
    @Published private(set) var byModel: [String: APIUsage] = [:]
    private var day = ""

    private init() { load() }

    private var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func usage(from dict: [String: Any]) -> APIUsage {
        var u = APIUsage()
        u.inputTokens = dict["in"] as? Int ?? 0
        u.outputTokens = dict["out"] as? Int ?? 0
        u.cacheReadTokens = dict["cr"] as? Int ?? 0
        u.cacheCreationTokens = dict["cc"] as? Int ?? 0
        u.webSearches = dict["ws"] as? Int ?? 0
        return u
    }

    private static func dict(from u: APIUsage) -> [String: Int] {
        ["in": u.inputTokens, "out": u.outputTokens, "cr": u.cacheReadTokens, "cc": u.cacheCreationTokens, "ws": u.webSearches]
    }

    private func load() {
        day = todayKey
        let dict = d.dictionary(forKey: "usage-\(day)") ?? [:]
        calls = dict["calls"] as? Int ?? 0
        if let models = dict["models"] as? [String: [String: Any]] {
            byModel = models.mapValues(UsageTracker.usage(from:))
        } else if dict["in"] != nil {
            // Totals recorded before usage was kept per model; everything then ran on one model.
            byModel = ["claude-sonnet-5": UsageTracker.usage(from: dict)]
        } else {
            byModel = [:]
        }
        var total = APIUsage()
        for u in byModel.values { total.add(u) }
        usage = total
    }

    func record(_ u: APIUsage, model: String) {
        if day != todayKey { load() }
        calls += 1
        usage.add(u)
        var m = byModel[model] ?? APIUsage()
        m.add(u)
        byModel[model] = m
        d.set(["calls": calls, "models": byModel.mapValues(UsageTracker.dict(from:))], forKey: "usage-\(day)")
    }

    /// (input $/MTok, output $/MTok) for a model; cache reads billed at 10%, writes at 125%.
    static func prices(for model: String) -> (Double, Double) {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return (10, 50) }
        if m.contains("opus-5-5") { return (4, 20) }
        if m.contains("opus") { return (5, 25) }
        if m.contains("haiku-5") { return (0.10, 0.50) }
        if m.contains("haiku") { return (1, 5) }
        if m.contains("sonnet-4-6") { return (3, 15) }
        return (2, 10) // claude-sonnet-5, claude-sonnet-5-5
    }

    /// Web search is $10 per 1,000 searches on top of token costs.
    static let pricePerSearch = 0.01

    func estimatedCost() -> Double {
        byModel.reduce(0) { sum, entry in
            let (i, o) = UsageTracker.prices(for: entry.key)
            let u = entry.value
            return sum + (Double(u.inputTokens) * i
                          + Double(u.cacheReadTokens) * i * 0.1
                          + Double(u.cacheCreationTokens) * i * 1.25
                          + Double(u.outputTokens) * o) / 1_000_000
                + Double(u.webSearches) * UsageTracker.pricePerSearch
        }
    }

    func summary() -> String {
        if day != todayKey { load() }
        let cost = estimatedCost()
        let searches = usage.webSearches > 0 ? " · \(usage.webSearches) search\(usage.webSearches == 1 ? "" : "es")" : ""
        return String(format: "Today: %d checks%@ · ~$%.2f", calls, searches, cost)
    }
}
