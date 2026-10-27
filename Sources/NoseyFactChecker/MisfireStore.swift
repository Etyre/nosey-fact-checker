import Foundation
import Combine

/// A flag that turned out to be wrong: the model withdrew it in chat, or the user marked it as not an
/// error. Misfires never expire; every background check is told about them and any candidate that
/// matches one is dropped before it can become a new flag.
struct Misfire: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    /// The claim as originally flagged (close to verbatim from the screen).
    let claim: String
    /// What the flag said was wrong with it.
    let summary: String
    /// Why the flag was withdrawn, in the model's or the user's words.
    let reason: String
    let findingID: UUID?
}

/// Fuzzy matching shared by duplicate detection and misfire suppression.
enum ClaimText {
    /// Normalized word set used for fuzzy duplicate detection.
    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }

    /// True when the two claims share at least 60% of their words (Jaccard), or are identical.
    static func similar(_ a: String, _ b: String) -> Bool {
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return a == b }
        let inter = Double(wa.intersection(wb).count)
        let union = Double(wa.union(wb).count)
        return inter / union >= 0.6
    }
}

/// Persisted at ~/Library/Application Support/Nosey/misfires.json. Newest first.
@MainActor
final class MisfireStore: ObservableObject {
    static let shared = MisfireStore()
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("misfires.json") }

    @Published private(set) var misfires: [Misfire] = []

    private init() {
        if let data = try? Data(contentsOf: MisfireStore.fileURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            misfires = (try? dec.decode([Misfire].self, from: data)) ?? []
        }
    }

    /// Records a misfire. A claim already on the list is not added twice.
    @discardableResult
    func add(claim: String, summary: String, reason: String, findingID: UUID?) -> Misfire {
        if let existing = match(for: claim) { return existing }
        let m = Misfire(id: UUID(), date: Date(), claim: claim, summary: summary, reason: reason, findingID: findingID)
        misfires.insert(m, at: 0)
        save()
        FileLog.write("misfire recorded: \"\(claim)\" :: \(reason)")
        return m
    }

    func remove(_ id: UUID) {
        misfires.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        misfires = []
        save()
    }

    /// The misfire this claim matches, if any (same text or a close restatement).
    func match(for claim: String) -> Misfire? {
        misfires.first { ClaimText.similar($0.claim, claim) }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(misfires) else { return }
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        try? data.write(to: MisfireStore.fileURL, options: .atomic)
    }
}
