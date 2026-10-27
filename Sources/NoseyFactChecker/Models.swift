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
    /// Set when the flag was withdrawn (the model retracted it in chat, or the user marked it as not an
    /// error). The claim is then also on the misfire list.
    var retractedAt: Date? = nil

    var captureURLs: [URL] { captureFiles.map { Paths.captures.appendingPathComponent($0) } }

    func isSimilar(to other: Finding) -> Bool { ClaimText.similar(claim, other.claim) }

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
    /// Web searches the API ran for us; billed per search on top of tokens.
    var webSearches = 0

    init() {}
    init(json: [String: Any]?) {
        guard let json else { return }
        inputTokens = json["input_tokens"] as? Int ?? 0
        outputTokens = json["output_tokens"] as? Int ?? 0
        cacheReadTokens = json["cache_read_input_tokens"] as? Int ?? 0
        cacheCreationTokens = json["cache_creation_input_tokens"] as? Int ?? 0
        webSearches = APIUsage.searches(in: json)
    }

    static func searches(in json: [String: Any]) -> Int {
        (json["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0
    }

    mutating func add(_ other: APIUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
        webSearches += other.webSearches
    }
}
