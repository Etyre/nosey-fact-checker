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
                let (_, usage) = try await client.streamChat(
                    model: settings.model,
                    effort: settings.effort == "low" ? "medium" : settings.effort,
                    system: self.systemPrompt,
                    messages: self.apiMessages(),
                    onText: { [weak self] delta in
                        guard let self, assistantIndex < self.messages.count else { return }
                        self.messages[assistantIndex].text += delta
                    })
                UsageTracker.shared.record(usage)
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
            if assistantIndex < self.messages.count { self.messages[assistantIndex].streaming = false }
            self.isStreaming = false
        }
    }

    var restoreDraft: ((String) -> Void)?

    func stop() { task?.cancel() }

    private var systemPrompt: String {
        finding != nil ? AppSettings.shared.chatPrompt
            : AppSettings.shared.chatPrompt + "\n\nIn this conversation you have not flagged anything yet; the user is asking about their screen or about fact-checking in general. If they attach a screenshot, examine it and answer their question."
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
                out.append(["role": "assistant", "content": m.text])
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
                let caps = try await engine.capturer.captureAll()
                session.pendingImages = caps.map(\.jpegData)
            } catch {
                session.error = error.localizedDescription
            }
        }
    }
}
