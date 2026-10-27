import Foundation
import Combine
import AppKit

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var images: [Data] = []        // attached to user messages only
    var hidden = false             // seed messages rendered as the finding card instead
    var streaming = false
    /// Status line shown while the model is doing something other than writing (a web search).
    var activity: String?
    /// Web searches the model ran for this reply, and the pages it cited.
    var searches: [String] = []
    var sources: [Source] = []
    /// The assistant turn's content blocks as the API returned them (assistant messages only). Sent back
    /// in place of `text` on later turns so encrypted search results and citations survive the round trip.
    var content: [[String: Any]] = []
    /// Set when this reply withdrew the flag; the model's one-line reason. The marker line itself is
    /// removed from `text` (it stays in `content`, so later turns still see it).
    var retraction: String?

    static func == (a: ChatMessage, b: ChatMessage) -> Bool {
        a.id == b.id && a.role == b.role && a.text == b.text && a.images == b.images && a.hidden == b.hidden
            && a.streaming == b.streaming && a.activity == b.activity && a.searches == b.searches && a.sources == b.sources
            && a.content.count == b.content.count && a.retraction == b.retraction
    }

    /// Splits off a trailing "RETRACTED: ..." line (bold or plain) the model was told to write when it
    /// withdraws a flag. Returns the text without that line, and the reason.
    static func splitRetraction(_ text: String) -> (text: String, reason: String?) {
        let pattern = #"(?m)^[ \t*_]*RETRACTED[ \t*_]*:[ \t*_]*(.+?)[ \t*_]*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(m.range, in: text), let r = Range(m.range(at: 1), in: text) else { return (text, nil) }
        let reason = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return (text, nil) }
        var rest = text; rest.removeSubrange(whole)
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), reason)
    }
}

/// One conversation, either about a specific finding or a free-form chat about the screen.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id: UUID
    let finding: Finding?
    let created = Date()
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var error: String?
    @Published var pendingImages: [Data] = []
    /// True once the flag this chat is about has been withdrawn (by the model or the user).
    @Published private(set) var withdrawn: Bool
    /// Set by the controller: records the misfire with the engine.
    var onWithdraw: ((Finding, String) -> Void)?
    private var task: Task<Void, Never>?
    private let client: AnthropicClient

    var title: String {
        if let finding { return String(finding.summary.prefix(70)) }
        return "Free chat · " + created.formatted(date: .omitted, time: .shortened)
    }

    init(finding: Finding?, client: AnthropicClient) {
        self.id = finding?.id ?? UUID()
        self.finding = finding
        self.client = client
        self.withdrawn = finding?.retractedAt != nil
        if let finding {
            let images = finding.captureURLs.compactMap { try? Data(contentsOf: $0) }
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            messages = [
                ChatMessage(role: .user,
                            text: "Screenshot(s) of my \(max(1, images.count)) display(s), captured \(f.string(from: finding.date)). Fact-check what is on screen.",
                            images: images, hidden: true),
                ChatMessage(role: .assistant, text: finding.assistantText, hidden: true),
            ]
        }
    }

    var visibleMessages: [ChatMessage] { messages.filter { !$0.hidden } }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        error = nil
        var user = ChatMessage(role: .user, text: trimmed)
        user.images = pendingImages
        pendingImages = []
        messages.append(user)
        messages.append(ChatMessage(role: .assistant, text: "", streaming: true))
        isStreaming = true
        let assistantIndex = messages.count - 1
        let settings = AppSettings.shared

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await client.streamChat(
                    model: settings.model,
                    effort: settings.effort == "low" ? "medium" : settings.effort,
                    system: self.systemPrompt,
                    messages: self.apiMessages(),
                    maxSearches: settings.chatSearches,
                    onText: { [weak self] delta in
                        guard let self, assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].text += delta
                    },
                    onActivity: { [weak self] status in
                        guard let self, assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].activity = status
                    })
                if assistantIndex < self.messages.count {
                    self.messages[assistantIndex].content = reply.content
                    self.messages[assistantIndex].searches = reply.searches
                    self.messages[assistantIndex].sources = reply.sources
                    if self.finding != nil {
                        let (text, reason) = ChatMessage.splitRetraction(self.messages[assistantIndex].text)
                        if let reason {
                            self.messages[assistantIndex].text = text
                            self.messages[assistantIndex].retraction = reason
                            self.withdraw(reason: reason)
                        }
                    }
                }
                UsageTracker.shared.record(reply.usage)
            } catch is CancellationError {
                // user pressed Stop; keep whatever arrived
            } catch {
                self.error = error.localizedDescription
                // Drop the failed exchange so the transcript still alternates user/assistant.
                if assistantIndex < self.messages.count, self.messages[assistantIndex].text.isEmpty {
                    self.messages.remove(at: assistantIndex)
                    let failedUser = self.messages.removeLast()
                    self.pendingImages = failedUser.images
                    self.restoreDraft?(failedUser.text)
                }
            }
            if assistantIndex < self.messages.count {
                self.messages[assistantIndex].streaming = false
                self.messages[assistantIndex].activity = nil
            }
            self.isStreaming = false
        }
    }

    var restoreDraft: ((String) -> Void)?

    func stop() { task?.cancel() }

    /// Withdraws the flag this chat is about and records it as a misfire. No-op for free chats or when
    /// the flag is already withdrawn.
    func withdraw(reason: String) {
        guard let finding, !withdrawn else { return }
        withdrawn = true
        onWithdraw?(finding, reason)
    }

    private var systemPrompt: String {
        if finding != nil {
            var p = AppSettings.shared.chatPrompt + "\n\n" + AppSettings.retractionAddendum
            if withdrawn { p += "\n\nYou have already withdrawn this flag earlier in the conversation; it is recorded as a misfire." }
            return p
        }
        return AppSettings.shared.chatPrompt + "\n\nIn this conversation you have not flagged anything yet; the user is asking about their screen or about fact-checking in general. If they attach a screenshot, examine it and answer their question."
    }

    /// Builds the API `messages` array. Images ride along with the user message they were attached to;
    /// the first user message gets a cache breakpoint so the screenshot is not re-billed every turn.
    private func apiMessages() -> [[String: Any]] {
        var out: [[String: Any]] = []
        var firstUserSeen = false
        for m in messages where !(m.streaming && m.text.isEmpty) {
            switch m.role {
            case .user:
                var content: [[String: Any]] = m.images.map(AnthropicClient.imageBlock)
                var textBlock: [String: Any] = ["type": "text", "text": m.text]
                if !firstUserSeen && !m.images.isEmpty {
                    textBlock["cache_control"] = ["type": "ephemeral"]
                }
                firstUserSeen = true
                content.append(textBlock)
                out.append(["role": "user", "content": content])
            case .assistant:
                // A reply that ran searches must go back block-for-block; a plain reply (or one cut short by
                // Stop, whose blocks were never completed) goes back as text.
                if !m.content.isEmpty, !m.streaming {
                    out.append(["role": "assistant", "content": m.content])
                } else {
                    out.append(["role": "assistant", "content": m.text])
                }
            }
        }
        return out
    }
}

/// Owns all chat sessions and which one is showing.
@MainActor
final class ChatController: ObservableObject {
    @Published var sessions: [ChatSession] = []     // newest first
    @Published var current: ChatSession?
    @Published var focusToken = 0
    @Published var draft = ""
    let client: AnthropicClient
    weak var engine: FactCheckEngine?

    init(client: AnthropicClient) { self.client = client }

    func session(for finding: Finding) -> ChatSession {
        if let s = sessions.first(where: { $0.id == finding.id }) { return s }
        let s = ChatSession(finding: finding, client: client)
        s.restoreDraft = { [weak self] t in self?.draft = t }
        s.onWithdraw = { [weak self] f, reason in self?.engine?.withdraw(f.id, reason: reason) }
        sessions.insert(s, at: 0)
        return s
    }

    func newFreeSession() -> ChatSession {
        let s = ChatSession(finding: nil, client: client)
        s.restoreDraft = { [weak self] t in self?.draft = t }
        sessions.insert(s, at: 0)
        return s
    }

    /// Picks what to show when the hotkey is pressed with no explicit target: the newest finding, else a free chat.
    func defaultSession() -> ChatSession {
        if let current { return current }
        if let f = engine?.findings.first { return session(for: f) }
        return newFreeSession()
    }

    func attachCurrentScreen(to session: ChatSession) {
        guard let engine else { return }
        Task {
            do {
                engine.capturer.excludedBundleIDs = Set(AppSettings.shared.excludedApps)
                let caps = try await engine.capturer.captureAll()
                session.pendingImages = caps.map(\.jpegData)
            } catch {
                session.error = error.localizedDescription
            }
        }
    }
}
