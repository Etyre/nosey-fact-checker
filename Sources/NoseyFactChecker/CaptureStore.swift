import Foundation
import os

private let log = Logger(subsystem: "com.elityre.nosey", category: "store")

/// Saves screenshots and findings under ~/Library/Application Support/Nosey and prunes old ones.
final class CaptureStore {
    private let fm = FileManager.default
    private var lastPrune = Date.distantPast

    init() {
        try? fm.createDirectory(at: Paths.captures, withIntermediateDirectories: true)
    }

    /// Writes each display capture to disk; returns the file names.
    func save(_ captures: [DisplayCapture], at date: Date) -> [String] {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: date)
        var names: [String] = []
        for c in captures {
            let name = "\(stamp)-d\(c.displayIndex).jpg"
            do {
                try c.jpegData.write(to: Paths.captures.appendingPathComponent(name), options: .atomic)
                names.append(name)
            } catch {
                log.error("save failed: \(error.localizedDescription)")
            }
        }
        return names
    }

    /// Deletes captures older than `hours`. Runs at most every 10 minutes unless forced.
    func pruneIfNeeded(retentionHours hours: Double, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPrune) > 600 else { return }
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        guard let items = try? fm.contentsOfDirectory(at: Paths.captures, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var removed = 0
        for url in items {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if mod < cutoff { try? fm.removeItem(at: url); removed += 1 }
        }
        if removed > 0 { log.info("pruned \(removed) old captures") }
    }

    func loadFindings() -> [Finding] {
        guard let data = try? Data(contentsOf: Paths.findingsFile),
              let list = try? JSONDecoder().decode([Finding].self, from: data) else { return [] }
        return list
    }

    func saveFindings(_ findings: [Finding]) {
        guard let data = try? JSONEncoder().encode(findings) else { return }
        try? data.write(to: Paths.findingsFile, options: .atomic)
    }
}
