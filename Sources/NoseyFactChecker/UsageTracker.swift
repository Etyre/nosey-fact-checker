import Foundation
import Combine

/// Tracks per-day API usage and estimates cost. The estimate uses first-party list prices and is
/// approximate; the Anthropic Console has the real numbers.
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()
    private let d = UserDefaults.standard

    @Published private(set) var calls = 0
    @Published private(set) var usage = APIUsage()
    private var day = ""

    private init() { load() }

    private var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func load() {
        day = todayKey
        let dict = d.dictionary(forKey: "usage-\(day)") ?? [:]
        calls = dict["calls"] as? Int ?? 0
        var u = APIUsage()
        u.inputTokens = dict["in"] as? Int ?? 0
        u.outputTokens = dict["out"] as? Int ?? 0
        u.cacheReadTokens = dict["cr"] as? Int ?? 0
        u.cacheCreationTokens = dict["cc"] as? Int ?? 0
        usage = u
    }

    func record(_ u: APIUsage) {
        if day != todayKey { load() }
        calls += 1
        usage.add(u)
        d.set(["calls": calls, "in": usage.inputTokens, "out": usage.outputTokens,
               "cr": usage.cacheReadTokens, "cc": usage.cacheCreationTokens], forKey: "usage-\(day)")
    }

    /// (input $/MTok, output $/MTok) for the configured model; cache reads billed at 10%, writes at 125%.
    static func prices(for model: String) -> (Double, Double) {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return (10, 50) }
        if m.contains("opus") { return (5, 25) }
        if m.contains("haiku") { return (1, 5) }
        if m.contains("sonnet-4-6") { return (3, 15) }
        return (2, 10) // claude-sonnet-5
    }

    func estimatedCost(model: String) -> Double {
        let (i, o) = UsageTracker.prices(for: model)
        let u = usage
        return (Double(u.inputTokens) * i
                + Double(u.cacheReadTokens) * i * 0.1
                + Double(u.cacheCreationTokens) * i * 1.25
                + Double(u.outputTokens) * o) / 1_000_000
    }

    func summary(model: String) -> String {
        if day != todayKey { load() }
        let cost = estimatedCost(model: model)
        return String(format: "Today: %d checks · ~$%.2f", calls, cost)
    }
}
