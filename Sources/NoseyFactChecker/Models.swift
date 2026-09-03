import Foundation

/// A single flagged claim.
struct Finding: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let claim: String
    let summary: String
    let explanation: String
    let confidence: Double
    let display: Int
    /// File names (inside `Paths.captures`) of the screenshots this finding came from, one per display.
    let captureFiles: [String]
    var read: Bool

    var captureURLs: [URL] { captureFiles.map { Paths.captures.appendingPathComponent($0) } }

    /// Normalized word set used for fuzzy duplicate detection.
    var claimWords: Set<String> {
        Set(claim.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }

    func isSimilar(to other: Finding) -> Bool {
        let a = claimWords, b = other.claimWords
        guard !a.isEmpty, !b.isEmpty else { return claim == other.claim }
        let inter = Double(a.intersection(b).count)
        let union = Double(a.union(b).count)
        return inter / union >= 0.6
    }

    /// Text shown as the assistant's opening message in the chat for this finding.
    var assistantText: String {
        let pct = Int((confidence * 100).rounded())
        return "I flagged this on your screen (display \(display)):\n\n“\(claim)”\n\n**\(summary)**\n\n\(explanation)\n\nConfidence: \(pct)%. Ask me anything about it, or push back if you think I'm wrong."
    }
}

/// Raw finding as returned by the model, before filtering.
struct RawFinding: Decodable {
    let claim: String
    let summary: String
    let explanation: String
    let confidence: Double
    let display: Int
}

struct FactCheckResponse: Decodable {
    let findings: [RawFinding]
}

struct APIUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0

    init() {}
    init(json: [String: Any]?) {
        guard let json else { return }
        inputTokens = json["input_tokens"] as? Int ?? 0
        outputTokens = json["output_tokens"] as? Int ?? 0
        cacheReadTokens = json["cache_read_input_tokens"] as? Int ?? 0
        cacheCreationTokens = json["cache_creation_input_tokens"] as? Int ?? 0
    }

    mutating func add(_ other: APIUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
    }
}
