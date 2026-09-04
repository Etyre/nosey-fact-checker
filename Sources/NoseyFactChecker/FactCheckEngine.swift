import Foundation
import AppKit
import Combine
import os
import CoreGraphics

private let log = Logger(subsystem: "com.elityre.nosey", category: "engine")

enum EngineError: LocalizedError {
    case timeout(String)
    var errorDescription: String? {
        switch self { case .timeout(let what): return "\(what) timed out" }
    }
}

/// Plain-text log at ~/Library/Application Support/Nosey/nosey.log (os_log entries proved hard to
/// retrieve). Rotated when it passes 2 MB.
enum FileLog {
    static let url = Paths.appSupport.appendingPathComponent("nosey.log")
    private static let queue = DispatchQueue(label: "nosey.filelog")
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("old.log"))
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Runs `op` but gives up after `seconds`. ScreenCaptureKit calls have been observed to hang across sleep.
func withTimeout<T>(_ seconds: Double, _ what: String, _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw EngineError.timeout(what)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

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
    private var inFlightSince = Date.distantPast

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
        FileLog.write("engine init; \(findings.count) stored findings")
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                Task { @MainActor in self?.handleWake(n.name.rawValue) }
            }
        }
        settings.$intervalSeconds
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &cancellables)
    }

    /// Paused is the only state that stops the loop; an error is shown but checks keep retrying.
    private func handleWake(_ reason: String) {
        FileLog.write("wake (\(reason)); resetting in-flight state and re-checking")
        inFlight = false
        lastSignatures = [:]
        backoffUntil = .distantPast
        if isWatching {
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await cycle(force: true)
            }
        }
    }

    var isPaused: Bool { if case .paused = state { return true } else { return false } }
    var isWatching: Bool { !isPaused }
    var unreadCount: Int { findings.filter { !$0.read }.count }

    // MARK: Control

    func start() {
        FileLog.write("start watching (interval \(Int(settings.intervalSeconds))s)")
        state = .watching
        lastNote = "Watching"
        reschedule()
        Task { await cycle(force: true) }
    }

    func pause(for interval: TimeInterval? = nil) {
        let until = interval.map { Date().addingTimeInterval($0) }
        FileLog.write("paused" + (until.map { " until \($0)" } ?? ""))
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
        if inFlight {
            // Watchdog: a cycle that has been "in flight" for minutes is hung (seen across sleep). Abandon it.
            if Date().timeIntervalSince(inFlightSince) > 180 {
                FileLog.write("watchdog: abandoning cycle stuck since \(inFlightSince)")
                inFlight = false
            } else {
                return
            }
        }
        if !force {
            guard isWatching, Date() >= backoffUntil else { return }
        }
        inFlight = true
        inFlightSince = Date()
        defer { inFlight = false }

        do {
            capturer.maxEdge = Int(settings.maxImageEdge)
            let capturer = self.capturer
            let captures = try await withTimeout(30, "Screen capture") { try await capturer.captureAll() }
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
            let client = self.client, model = settings.model, effort = settings.effort, prompt = settings.factCheckPrompt
            let images = captures.map(\.jpegData)
            let userText = FactCheckEngine.userText(displayCount: captures.count, date: now, recent: Array(recent))
            let (raw, u) = try await withTimeout(120, "Fact-check request") { try await client.factCheck(
                model: model, effort: effort, system: prompt, images: images, userText: userText) }
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
            FileLog.write("check ok: \(captures.count) display(s), \(u.inputTokens) in / \(u.outputTokens) out, \(raw.count) candidate(s), \(fresh.count) new" + (raw.isEmpty ? "" : " :: " + raw.map { "[\(String(format: "%.2f", $0.confidence))] \($0.summary)" }.joined(separator: " | ")))
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
            FileLog.write("check FAILED: \(msg)")
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
