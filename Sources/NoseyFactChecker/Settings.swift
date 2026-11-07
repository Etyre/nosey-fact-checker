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

    /// Model for the background checks. They run every few seconds, so a cheap model matters most here.
    @Published var checkModel: String { didSet { d.set(checkModel, forKey: "checkModel") } }
    /// Model for the chat window, where the model argues a flag with the user.
    @Published var chatModel: String { didSet { d.set(chatModel, forKey: "chatModel") } }
    /// Required by identity-linked API keys; sent as the anthropic-workspace-id header when non-empty.
    @Published var workspaceID: String { didSet { d.set(workspaceID, forKey: "workspaceID") } }
    @Published var effort: String { didSet { d.set(effort, forKey: "effort") } }
    @Published var intervalSeconds: Double { didSet { d.set(intervalSeconds, forKey: "intervalSeconds") } }
    /// Fraction (0–1) of the 64×64 thumbnail cells that must change strongly (vs. the last screenshot
    /// actually sent) for a check to be sent immediately: window switches, scrolling, big edits.
    @Published var changeThreshold: Double { didSet { d.set(changeThreshold, forKey: "changeThreshold") } }
    /// Fraction of cells that must change slightly (vs. the last sent screenshot) to count as a minor edit,
    /// e.g. a typed sentence. A minor edit is sent once the screen has been still for `settleTicks` ticks.
    /// Around 0.003 ignores the blinking caret and the menu bar clock but catches one line of text.
    @Published var fineChangeThreshold: Double { didSet { d.set(fineChangeThreshold, forKey: "fineChangeThreshold") } }
    /// Consecutive unchanged ticks required before a pending minor edit is sent.
    @Published var settleTicks: Int { didSet { d.set(settleTicks, forKey: "settleTicks") } }
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
    /// Gives the model Anthropic's server-side web search tool. Each search is billed ($10 per 1,000) and
    /// its results add input tokens, so the two limits below cap searches per request.
    @Published var webSearch: Bool { didSet { d.set(webSearch, forKey: "webSearch") } }
    /// Max searches per background check (0 disables search for checks while keeping it in chat).
    @Published var checkSearchMaxUses: Int { didSet { d.set(checkSearchMaxUses, forKey: "checkSearchMaxUses") } }
    /// Max searches per chat reply.
    @Published var chatSearchMaxUses: Int { didSet { d.set(chatSearchMaxUses, forKey: "chatSearchMaxUses") } }
    /// Bundle identifiers of apps whose windows are left out of every screenshot. Whatever is behind
    /// such a window shows through in its place. Signal is excluded by default.
    @Published var excludedApps: [String] { didSet { d.set(excludedApps, forKey: "excludedApps") } }

    /// Not persisted: status text for the hotkey registration, shown in Settings.
    @Published var hotKeyStatus: String = ""

    private init() {
        checkModel = d.string(forKey: "checkModel") ?? "claude-haiku-5-5"
        // Before the split there was one "model" setting; a custom value carries over to chat.
        chatModel = d.string(forKey: "chatModel") ?? d.string(forKey: "model") ?? "claude-sonnet-5"
        workspaceID = d.string(forKey: "workspaceID") ?? ""
        effort = d.string(forKey: "effort") ?? "low"
        intervalSeconds = d.object(forKey: "intervalSeconds") as? Double ?? 5
        changeThreshold = d.object(forKey: "changeThreshold") as? Double ?? 0.01
        fineChangeThreshold = d.object(forKey: "fineChangeThreshold") as? Double ?? 0.003
        settleTicks = d.object(forKey: "settleTicks") as? Int ?? 2
        minConfidence = d.object(forKey: "minConfidence") as? Double ?? 0.75
        hotKey = d.string(forKey: "hotKey") ?? "ctrl+cmd+j"
        dismissHotKey = d.string(forKey: "dismissHotKey") ?? "ctrl+cmd+k"
        chatWindowSize = ChatWindowSize(rawValue: d.string(forKey: "chatWindowSize") ?? "") ?? .quarter
        retentionHours = d.object(forKey: "retentionHours") as? Double ?? 24
        factCheckPrompt = d.string(forKey: "factCheckPrompt") ?? AppSettings.defaultFactCheckPrompt
        chatPrompt = d.string(forKey: "chatPrompt") ?? AppSettings.defaultChatPrompt
        maxImageEdge = d.object(forKey: "maxImageEdge") as? Double ?? 1568
        notifySound = d.object(forKey: "notifySound") as? Bool ?? true
        launchAtLogin = d.object(forKey: "launchAtLogin") as? Bool ?? false
        startWatchingOnLaunch = d.object(forKey: "startWatchingOnLaunch") as? Bool ?? true
        webSearch = d.object(forKey: "webSearch") as? Bool ?? true
        checkSearchMaxUses = d.object(forKey: "checkSearchMaxUses") as? Int ?? 2
        chatSearchMaxUses = d.object(forKey: "chatSearchMaxUses") as? Int ?? 5
        excludedApps = d.stringArray(forKey: "excludedApps") ?? AppSettings.defaultExcludedApps
    }

    static let defaultExcludedApps = ["org.whispersystems.signal-desktop"]

    /// Searches allowed for a background check, after the toggle.
    var checkSearches: Int { webSearch ? checkSearchMaxUses : 0 }
    /// Searches allowed for a chat reply, after the toggle.
    var chatSearches: Int { webSearch ? chatSearchMaxUses : 0 }

    /// Appended to the system prompt (after the cached part) whenever the web search tool is on.
    static let webSearchAddendum = """
    You have a web_search tool. Use it to verify a claim you are not sure about, and to check claims about things that may have changed after your knowledge cutoff (recent events, current office-holders, prices, versions, results): with search available, you may flag those too, but only once a search has confirmed they are wrong. Searches cost money and time, so search only when it changes what you would say, and keep queries specific. If a search does not settle the question, say so rather than guessing.
    """

    /// Appended to the chat prompt whenever the model has the capture_screen tool.
    static let captureToolAddendum = """
    You have a capture_screen tool that takes a fresh screenshot of all the user's displays and returns it to you. The screenshots already in this conversation show the screen as it was when they were taken, possibly some time ago. Call the tool when the user refers to what is on their screen now, asks what changed, or asks you to look again, and whenever your answer depends on the current state of the screen. Do not call it for questions about the claim itself that the existing screenshot or your knowledge can answer. Nosey's own chat window is excluded from the capture, so you will not see this conversation in it.
    """

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
    - Anything in the "Already flagged" or "Misfires" lists, or restatements of them.
    - Text that is itself quoting, discussing, or debunking a false claim.

    Prefer silence. A missed borderline case costs nothing; a false alarm interrupts the user. Most screenshots should produce zero findings.

    For each finding give: the claim (short, close to verbatim, under 200 characters); a summary of at most 100 characters that states what is wrong and the correct fact (it appears in a small notification, so make every word count); a fuller explanation of 2 to 4 sentences with the basis for your correction; a confidence between 0 and 1; and the 1-based number of the display the claim appeared on.
    """

    /// Appended to the chat prompt whenever the conversation is about a flag. The marker line it asks
    /// for is what `ChatSession` parses to record a misfire; it is kept out of the editable prompt so
    /// it cannot be lost.
    static let retractionAddendum = """
    If during this conversation you conclude that your flag was a mistake, because the claim is actually correct, defensible, or not the kind of statement you should have flagged, say so plainly in your reply and then, as the very last line of that same reply, on its own line, write exactly:
    RETRACTED: <one sentence saying what you got wrong>
    Nosey records that line as a misfire and will never flag this claim again, so include it only when you are genuinely withdrawing the flag, not when you are merely less sure, and only for the claim you flagged. Once you have written it, do not write it again in this conversation.
    """

    static let defaultChatPrompt = """
    You are Nosey, a background fact-checker that watches the user's screen. Earlier you flagged a statement on their screen as false or misleading; the screenshot(s) and your finding are in this conversation. Now the user wants to discuss it.

    Answer questions directly and concisely. If the user pushes back, engage with their argument honestly: concede when they are right or when the claim turns out to be defensible, and hold your position with evidence when it is not. Distinguish clearly between what you know and what you are unsure of, and say so when something may have changed after your knowledge cutoff. Use plain prose with light formatting and no headers.
    """
}

/// Text the user has typed but not yet submitted (the chat input, the hotkey and bundle-ID fields in
/// Settings). Saved to UserDefaults on every change and restored when the field is next shown, so a draft
/// survives switching conversations, closing the window and restarting Nosey. Cleared only when the text
/// is submitted. Fields bound straight to an `AppSettings` property persist on their own and need none of this.
enum Drafts {
    private static let d = UserDefaults.standard
    static func load(_ key: String) -> String? { d.string(forKey: "draft." + key) }
    static func save(_ key: String, _ text: String) {
        if text.isEmpty { d.removeObject(forKey: "draft." + key) } else { d.set(text, forKey: "draft." + key) }
    }
    static func clear(_ key: String) { d.removeObject(forKey: "draft." + key) }
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
