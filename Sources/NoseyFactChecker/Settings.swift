import Foundation
import Combine

enum ChatWindowSize: String, CaseIterable, Identifiable {
    case quarter, half, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quarter: return "Quarter"
        case .half: return "Half"
        case .full: return "Full"
        }
    }
}

/// All user-tunable settings. Persisted to UserDefaults (except the API key, see `APIKeyStore`).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    /// Required by identity-linked API keys; sent as the anthropic-workspace-id header when non-empty.
    @Published var workspaceID: String { didSet { d.set(workspaceID, forKey: "workspaceID") } }
    @Published var effort: String { didSet { d.set(effort, forKey: "effort") } }
    @Published var intervalSeconds: Double { didSet { d.set(intervalSeconds, forKey: "intervalSeconds") } }
    /// Fraction (0–1) of the 32×32 thumbnail cells that must change before a new check is sent.
    @Published var changeThreshold: Double { didSet { d.set(changeThreshold, forKey: "changeThreshold") } }
    @Published var minConfidence: Double { didSet { d.set(minConfidence, forKey: "minConfidence") } }
    @Published var hotKey: String { didSet { d.set(hotKey, forKey: "hotKey") } }
    @Published var dismissHotKey: String { didSet { d.set(dismissHotKey, forKey: "dismissHotKey") } }
    @Published var chatWindowSize: ChatWindowSize { didSet { d.set(chatWindowSize.rawValue, forKey: "chatWindowSize") } }
    @Published var retentionHours: Double { didSet { d.set(retentionHours, forKey: "retentionHours") } }
    @Published var factCheckPrompt: String { didSet { d.set(factCheckPrompt, forKey: "factCheckPrompt") } }
    @Published var chatPrompt: String { didSet { d.set(chatPrompt, forKey: "chatPrompt") } }
    @Published var maxImageEdge: Double { didSet { d.set(maxImageEdge, forKey: "maxImageEdge") } }
    @Published var notifySound: Bool { didSet { d.set(notifySound, forKey: "notifySound") } }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var startWatchingOnLaunch: Bool { didSet { d.set(startWatchingOnLaunch, forKey: "startWatchingOnLaunch") } }

    /// Not persisted: status text for the hotkey registration, shown in Settings.
    @Published var hotKeyStatus: String = ""

    private init() {
        model = d.string(forKey: "model") ?? "claude-sonnet-5"
        workspaceID = d.string(forKey: "workspaceID") ?? ""
        effort = d.string(forKey: "effort") ?? "low"
        intervalSeconds = d.object(forKey: "intervalSeconds") as? Double ?? 5
        changeThreshold = d.object(forKey: "changeThreshold") as? Double ?? 0.01
        minConfidence = d.object(forKey: "minConfidence") as? Double ?? 0.75
        hotKey = d.string(forKey: "hotKey") ?? "alt+cmd+j"
        dismissHotKey = d.string(forKey: "dismissHotKey") ?? "alt+cmd+k"
        chatWindowSize = ChatWindowSize(rawValue: d.string(forKey: "chatWindowSize") ?? "") ?? .quarter
        retentionHours = d.object(forKey: "retentionHours") as? Double ?? 24
        factCheckPrompt = d.string(forKey: "factCheckPrompt") ?? AppSettings.defaultFactCheckPrompt
        chatPrompt = d.string(forKey: "chatPrompt") ?? AppSettings.defaultChatPrompt
        maxImageEdge = d.object(forKey: "maxImageEdge") as? Double ?? 1568
        notifySound = d.object(forKey: "notifySound") as? Bool ?? true
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
        startWatchingOnLaunch = d.object(forKey: "startWatchingOnLaunch") as? Bool ?? true
    }

    static let defaultFactCheckPrompt = """
    You are Nosey, a quiet background fact-checker. Every few seconds you receive screenshots of the user's screen(s). Your job is to notice statements on screen that are factually FALSE or MATERIALLY MISLEADING according to your knowledge, and report only those.

    Flag a statement only when ALL of these hold:
    - It is a concrete, checkable claim of fact: a date, number, statistic, scientific, historical or geographic fact, a quotation or attribution, a definition, or how something works.
    - You are confident it is wrong or seriously misleading, and you can state the correct information.
    - A reasonable reader would actually be misled by it.

    Do NOT flag:
    - Opinions, predictions, forecasts, jokes, satire, fiction, hypotheticals, rhetorical exaggeration, or marketing language.
    - Source code, terminal output, UI labels, file names, placeholder or test data, or anything that is obviously a draft being edited.
    - Anything you cannot verify or that may have changed after your knowledge cutoff: recent news, prices, current office-holders, software versions, sports results, live data. If it might have changed, stay silent.
    - Minor imprecision, rounding, informal phrasing, or claims that are approximately right.
    - Anything in the "Already flagged" list, or restatements of it.
    - Text that is itself quoting, discussing, or debunking a false claim.

    Prefer silence. A missed borderline case costs nothing; a false alarm interrupts the user. Most screenshots should produce zero findings.

    For each finding give: the claim (short, close to verbatim, under 200 characters); a summary of at most 100 characters that states what is wrong and the correct fact (it appears in a small notification, so make every word count); a fuller explanation of 2 to 4 sentences with the basis for your correction; a confidence between 0 and 1; and the 1-based number of the display the claim appeared on.
    """

    static let defaultChatPrompt = """
    You are Nosey, a background fact-checker that watches the user's screen. Earlier you flagged a statement on their screen as false or misleading; the screenshot(s) and your finding are in this conversation. Now the user wants to discuss it.

    Answer questions directly and concisely. If the user pushes back, engage with their argument honestly: concede when they are right or when the claim turns out to be defensible, and hold your position with evidence when it is not. Distinguish clearly between what you know and what you are unsure of, and say so when something may have changed after your knowledge cutoff. Use plain prose with light formatting and no headers.
    """
}

/// The API key lives in a 0600 file under Application Support (not UserDefaults, which is world-readable
/// plist). ANTHROPIC_API_KEY in the environment is used as a fallback when the app is launched from a shell.
enum APIKeyStore {
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("api-key") }

    static func read() -> String? {
        if let s = try? String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    static func write(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? FileManager.default.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        try? trimmed.write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Nosey", isDirectory: true)
    }
    static var captures: URL { appSupport.appendingPathComponent("captures", isDirectory: true) }
    static var findingsFile: URL { appSupport.appendingPathComponent("findings.json") }
}
