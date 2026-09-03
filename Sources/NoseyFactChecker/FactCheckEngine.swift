import Foundation
import Combine
import os
import CoreGraphics

private let log = Logger(subsystem: "com.elityre.nosey", category: "engine")

/// The capture → change-detect → fact-check → notify loop.
@MainActor
final class FactCheckEngine: ObservableObject {
    enum State: Equatable {
        case watching
        case paused(until: Date?)
        case error(String)
    }

    @Published private(set) var state: State = .paused(until: nil)
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastNote: String = "Not started"
    @Published private(set) var findings: [Finding] = []      // newest first
    @Published private(set) var inFlight = false

    var onNewFindings: (([Finding]) -> Void)?

    let capturer = ScreenCapturer()
    let store = CaptureStore()
    let client = AnthropicClient()
    private let settings = AppSettings.shared
    private let usage = UsageTracker.shared

    private var timer: Timer?
    private var lastSignatures: [CGDirectDisplayID: [Float]] = [:]
    private var backoffUntil = Date.distantPast
    /// Set after a failure so the next cycle calls the API even if the screen has not changed.
    private var retryPending = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        findings = store.loadFindings().sorted { $0.date > $1.date }
        settings.$intervalSeconds
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &cancellables)
    }

    /// Paused is the only state that stops the loop; an error is shown but checks keep retrying.
    var isPaused: Bool { if case .paused = state { return true } else { return false } }
    var isWatching: Bool { !isPaused }
    var unreadCount: Int { findings.filter { !$0.read }.count }

    // MARK: Control

    func start() {
        state = .watching
        lastNote = "Watching"
        reschedule()
        Task { await cycle(force: true) }
    }

    func pause(for interval: TimeInterval? = nil) {
        let until = interval.map { Date().addingTimeInterval($0) }
        state = .paused(until: until)
        lastNote = "Paused"
        timer?.invalidate(); timer = nil
        if let until {
            Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    if case .paused(let u) = self?.state ?? .watching, u == until { self?.start() }
                }
            }
        }
    }

    func checkNow() {
        Task { await cycle(force: true) }
    }

    func markRead(_ id: UUID) {
        guard let i = findings.firstIndex(where: { $0.id == id }), !findings[i].read else { return }
        findings[i].read = true
        store.saveFindings(findings)
    }

    func markAllRead() {
        for i in findings.indices { findings[i].read = true }
        store.saveFindings(findings)
    }

    func finding(id: UUID) -> Finding? { findings.first { $0.id == id } }

    private func reschedule() {
        timer?.invalidate()
        guard isWatching else { return }
        let interval = max(2, settings.intervalSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.cycle(force: false) }
        }
    }

    // MARK: The loop

    private func cycle(force: Bool) async {
        guard !inFlight else { return }
        if !force {
            guard isWatching, Date() >= backoffUntil else { return }
        }
        inFlight = true
        defer { inFlight = false }

        do {
            capturer.maxEdge = Int(settings.maxImageEdge)
            let captures = try await capturer.captureAll()
            guard !captures.isEmpty else { lastNote = "No displays found"; return }

            var changed = force || retryPending
            var maxDelta = 0.0
            for c in captures {
                let delta = ScreenCapturer.changedFraction(lastSignatures[c.displayID] ?? [], c.signature)
                maxDelta = max(maxDelta, delta)
                if delta >= settings.changeThreshold { changed = true }
                lastSignatures[c.displayID] = c.signature
            }
            guard changed else {
                lastNote = String(format: "Screen unchanged (%.1f%% delta)", maxDelta * 100)
                return
            }

            let now = Date()
            let files = store.save(captures, at: now)
            let recent = findings.filter { now.timeIntervalSince($0.date) < 24 * 3600 }.prefix(30)
            let (raw, u) = try await client.factCheck(
                model: settings.model,
                effort: settings.effort,
                system: settings.factCheckPrompt,
                images: captures.map(\.jpegData),
                userText: FactCheckEngine.userText(displayCount: captures.count, date: now, recent: Array(recent))
            )
            usage.record(u)
            lastCheck = now
            retryPending = false
            if case .error = state { state = .watching }

            var fresh: [Finding] = []
            for r in raw {
                guard r.confidence >= settings.minConfidence else { continue }
                let f = Finding(id: UUID(), date: now,
                                claim: r.claim.trimmingCharacters(in: .whitespacesAndNewlines),
                                summary: String(r.summary.prefix(140)),
                                explanation: r.explanation, confidence: min(1, max(0, r.confidence)),
                                display: max(1, r.display), captureFiles: files, read: false)
                let dup = findings.contains { $0.isSimilar(to: f) } || fresh.contains { $0.isSimilar(to: f) }
                if !dup { fresh.append(f) }
            }
            lastNote = raw.isEmpty ? "Checked: nothing flagged" : "Checked: \(raw.count) candidate(s), \(fresh.count) new"
            if !fresh.isEmpty {
                findings.insert(contentsOf: fresh, at: 0)
                store.saveFindings(findings)
                let hk = HotKeyManager.describe(settings.hotKey)
                for f in fresh.prefix(3) { Notifier.shared.post(f, hotKeyLabel: hk) }
                onNewFindings?(fresh)
            }
        } catch is CancellationError {
            // ignore
        } catch {
            let msg = error.localizedDescription
            log.error("cycle failed: \(msg, privacy: .public)")
            lastNote = msg
            state = .error(msg)
            retryPending = true
            // Missing key / permission: wait a while. Rate limit: back off. Everything else: brief pause.
            switch error {
            case APIError.noKey, CaptureError.noPermission: backoffUntil = Date().addingTimeInterval(60)
            case APIError.http(let code, _) where code == 429 || code >= 500: backoffUntil = Date().addingTimeInterval(45)
            default: backoffUntil = Date().addingTimeInterval(15)
            }
        }
        store.pruneIfNeeded(retentionHours: settings.retentionHours)
        pruneFindings()
    }

    private func pruneFindings() {
        let cutoff = Date().addingTimeInterval(-settings.retentionHours * 3600)
        let kept = findings.filter { $0.date >= cutoff }
        if kept.count != findings.count {
            findings = kept
            store.saveFindings(findings)
        }
    }

    static func userText(displayCount: Int, date: Date, recent: [Finding]) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        var s = "Screenshot(s) of \(displayCount) display(s), captured \(f.string(from: date)). Display N is image N in order.\n"
        if recent.isEmpty {
            s += "\nAlready flagged in the last 24 hours: none.\n"
        } else {
            s += "\nAlready flagged in the last 24 hours (do not repeat these or restatements of them):\n"
            for r in recent { s += "- \(r.claim)\n" }
        }
        s += "\nReport findings per your instructions. Return an empty list if nothing qualifies."
        return s
    }
}
