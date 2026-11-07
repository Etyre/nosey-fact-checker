import Foundation
import os

private let log = Logger(subsystem: "com.elityre.nosey", category: "api")

enum APIError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse(String)
    case stream(String)
    /// The model sent a message to Eli through the shared LLM inbox. The task that got this stops.
    case contactedEli(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "No API key. Open Settings and paste your Anthropic API key."
        case .contactedEli(let msg): return "The model contacted Eli (read it with llm-inbox): \(msg)"
        case .http(let code, let msg):
            if msg.contains("anthropic-workspace-id") {
                return "This API key is identity-linked and needs a Workspace ID. Paste it (wrkspc_…) in Settings; it is under Console › Settings › Workspaces."
            }
            return "API error \(code): \(msg)"
        case .badResponse(let msg): return "Unexpected API response: \(msg)"
        case .stream(let msg): return "Stream error: \(msg)"
        }
    }
}

/// A web page the model cited in a reply.
struct Source: Equatable, Hashable {
    let title: String
    let url: String
}

/// What came back from a streamed chat turn, beyond the text the user saw arrive.
struct ChatReply {
    var text = ""
    /// The turn as it must be replayed on later requests: the assistant content blocks exactly as the API
    /// returned them and, when the model took a screenshot, the tool result it was given followed by its
    /// continuation. Search results are encrypted and the API rejects a conversation where they were altered.
    var transcript: [[String: Any]] = []
    var searches: [String] = []
    var sources: [Source] = []
    /// Screenshots the model took with the capture_screen tool during this reply.
    var captures = 0
    var usage = APIUsage()

    /// Every assistant content block of the reply, across continuations.
    var blocks: [[String: Any]] {
        transcript.filter { ($0["role"] as? String) == "assistant" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
    }
}

/// Takes a fresh screenshot of every display and returns the JPEGs, one per display.
typealias ScreenCaptureProvider = @MainActor () async throws -> [Data]

/// Raw-HTTP client for the Claude Messages API (there is no official Swift SDK).
final class AnthropicClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Idle limit between bytes. A web search pauses the stream for a while, so this is generous.
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    /// A turn that uses server tools can be paused by the API (`pause_turn`); it resumes when the same
    /// content is sent back. A turn that calls the screenshot tool also takes a further request per call.
    /// This caps how many requests one turn may take.
    private static let maxContinuations = 8
    /// Screenshots the model may take in one reply. Each one adds a round trip and the image tokens.
    private static let maxCapturesPerReply = 3

    private func request(body: [String: Any]) throws -> URLRequest {
        guard let key = APIKeyStore.read() else { throw APIError.noKey }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let ws = AppSettings.shared.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ws.isEmpty { req.setValue(ws, forHTTPHeaderField: "anthropic-workspace-id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Adaptive thinking + effort are only valid on the 4.6+ generation; older models reject them.
    private static func supportsAdaptive(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("sonnet-5") || m.contains("opus-5") || m.contains("haiku-5") || m.contains("fable") || m.contains("mythos")
            || m.contains("opus-4-6") || m.contains("opus-4-7") || m.contains("opus-4-8") || m.contains("sonnet-4-6")
    }

    /// Server-side web search, the basic version: the model calls it directly and cites results in its
    /// text. The newer version routes searches through code execution, which hides the queries behind
    /// code blocks and often returns no citations; it did not save tokens in testing either.
    /// `maxUses` caps searches per request; each one is billed.
    static func webSearchTool(model: String, maxUses: Int) -> [String: Any] {
        ["type": "web_search_20250305", "name": "web_search", "max_uses": max(1, maxUses)]
    }

    /// Client tool the model can call during a chat to get a fresh screenshot of every display. Nosey takes
    /// the screenshot and returns the images as the tool result.
    static let captureToolName = "capture_screen"
    static func captureScreenTool() -> [String: Any] {
        [
            "name": captureToolName,
            "description": "Take a fresh screenshot of all of the user's displays right now and return the images. Use it when the screenshot you have may be out of date: the user refers to something now on their screen, asks what changed, or asks you to look again. Nosey's own chat window is left out of the capture.",
            "input_schema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ]
    }

    private static func baseBody(model: String, effort: String, system: [[String: Any]], maxTokens: Int,
                                 tools: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
        ]
        if !tools.isEmpty { body["tools"] = tools }
        if supportsAdaptive(model) {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        }
        return body
    }

    /// Every system prompt starts with the shared LLM-inbox preamble, then the user-editable prompt; that
    /// block is cached. `context` (the recent-flag and misfire lists) changes only when a flag is added or
    /// withdrawn, so it is cached too, behind its own breakpoint so a change to it does not rewrite the
    /// prompt. The short tool addenda come after both breakpoints, so toggling a tool does not invalidate
    /// either.
    private static func systemBlocks(prompt: String, context: String? = nil, webSearch: Bool,
                                     captureTool: Bool = false) throws -> [[String: Any]] {
        var blocks: [[String: Any]] = [["type": "text", "text": try LLMContact.systemPrompt(prompt), "cache_control": ["type": "ephemeral"]]]
        if let context, !context.isEmpty {
            blocks.append(["type": "text", "text": context, "cache_control": ["type": "ephemeral"]])
        }
        if webSearch { blocks.append(["type": "text", "text": AppSettings.webSearchAddendum]) }
        if captureTool { blocks.append(["type": "text", "text": AppSettings.captureToolAddendum]) }
        return blocks
    }

    /// The system prompt as one string, for the inbox record.
    private static func systemText(_ blocks: [[String: Any]]) -> String {
        blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    /// Runs the shared inbox check on one API response and, if the model contacted Eli, throws so the
    /// caller stops the task. `body` is the request that produced the response.
    private static func checkContact(body: [String: Any], response: [String: Any]) async throws {
        let system = (body["system"] as? [[String: Any]]).map(systemText) ?? (body["system"] as? String ?? "")
        if let c = await LLMContact.check(model: body["model"] as? String ?? "", system: system,
                                          messages: body["messages"] as? [[String: Any]] ?? [],
                                          response: response, tools: body["tools"] as? [[String: Any]] ?? []) {
            throw APIError.contactedEli(c.message)
        }
    }

    static func imageBlock(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    private static let findingsSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "findings": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "claim": ["type": "string"],
                        "summary": ["type": "string"],
                        "explanation": ["type": "string"],
                        "confidence": ["type": "number"],
                        "display": ["type": "integer"],
                    ],
                    "required": ["claim", "summary", "explanation", "confidence", "display"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["findings"],
        "additionalProperties": false,
    ]

    // MARK: Fact check (structured JSON output, non-streaming)

    /// `context` is the slowly changing text (recent flags, misfires) that rides in the cached system
    /// prompt; `userText` is the per-check text. `maxSearches` > 0 gives the model the web search tool.
    func factCheck(model: String, effort: String, system: String, context: String? = nil, images: [Data],
                   userText: String, maxSearches: Int = 0) async throws -> ([RawFinding], APIUsage) {
        var tools = maxSearches > 0 ? [AnthropicClient.webSearchTool(model: model, maxUses: maxSearches)] : []
        tools.append(try LLMContact.contactTool())
        var body = AnthropicClient.baseBody(model: model, effort: effort,
                                            system: try AnthropicClient.systemBlocks(prompt: system, context: context,
                                                                                     webSearch: maxSearches > 0),
                                            maxTokens: 4096, tools: tools)
        var outputConfig = body["output_config"] as? [String: Any] ?? [:]
        outputConfig["format"] = ["type": "json_schema", "schema": AnthropicClient.findingsSchema]
        body["output_config"] = outputConfig
        var content: [[String: Any]] = images.map(AnthropicClient.imageBlock)
        content.append(["type": "text", "text": userText])
        let userMessage: [String: Any] = ["role": "user", "content": content]

        var usage = APIUsage()
        var blocks: [[String: Any]] = []
        for attempt in 0...AnthropicClient.maxContinuations {
            body["messages"] = blocks.isEmpty ? [userMessage] : [userMessage, ["role": "assistant", "content": blocks]]
            let req = try request(body: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw APIError.http(code, AnthropicClient.errorMessage(data)) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIError.badResponse("not a JSON object")
            }
            usage.add(APIUsage(json: json["usage"] as? [String: Any]))
            try await AnthropicClient.checkContact(body: body, response: json)
            let stopReason = json["stop_reason"] as? String ?? ""
            blocks += json["content"] as? [[String: Any]] ?? []
            if stopReason == "tool_use" {
                // The only client tool here is contact_eli, and a call to it was caught just above.
                throw APIError.badResponse("unexpected tool call in a fact check")
            }
            if stopReason == "refusal" {
                log.notice("fact-check refused by safety classifier; treating as no findings")
                return ([], usage)
            }
            if stopReason == "pause_turn" {
                if attempt == AnthropicClient.maxContinuations { throw APIError.badResponse("turn paused too many times") }
                log.notice("fact-check paused after a search; resuming")
                continue
            }
            break
        }
        let text = AnthropicClient.finalText(blocks)
        guard !text.isEmpty else { throw APIError.badResponse("no text block") }
        let decoded = try JSONDecoder().decode(FactCheckResponse.self, from: Data(text.utf8))
        return (decoded.findings, usage)
    }

    /// The JSON answer is in the text blocks that follow the last search; citations can split it across
    /// several blocks, so they are joined. Any text written before a search is not part of the answer.
    private static func finalText(_ blocks: [[String: Any]]) -> String {
        let lastTool = blocks.lastIndex { ($0["type"] as? String) != "text" && ($0["type"] as? String) != "thinking" } ?? -1
        return blocks[(lastTool + 1)...]
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
    }

    // MARK: Chat (streaming SSE)

    /// Streams a reply. `onText` gets each text delta; `onActivity` gets a short status line (a search or
    /// screenshot in progress) or nil when it ends. Both run on the main actor. When `captureScreen` is given,
    /// the model gets the capture_screen tool and each call is answered with the images it returns. Returns
    /// the full reply, including the raw transcript to store for later turns.
    func streamChat(model: String, effort: String, system: String, messages: [[String: Any]], maxSearches: Int = 0,
                    captureScreen: ScreenCaptureProvider? = nil,
                    onText: @escaping @MainActor (String) -> Void,
                    onActivity: @escaping @MainActor (String?) -> Void = { _ in }) async throws -> ChatReply {
        var tools = maxSearches > 0 ? [AnthropicClient.webSearchTool(model: model, maxUses: maxSearches)] : []
        if captureScreen != nil { tools.append(AnthropicClient.captureScreenTool()) }
        tools.append(try LLMContact.contactTool())
        var body = AnthropicClient.baseBody(model: model, effort: effort,
                                            system: try AnthropicClient.systemBlocks(prompt: system, webSearch: maxSearches > 0,
                                                                                     captureTool: captureScreen != nil),
                                            maxTokens: 8192, tools: tools)
        body["stream"] = true

        var reply = ChatReply()
        var current: [[String: Any]] = []   // blocks of the assistant message being built
        for attempt in 0...AnthropicClient.maxContinuations {
            body["messages"] = messages + reply.transcript + (current.isEmpty ? [] : [["role": "assistant", "content": current]])
            let (stop, blocks) = try await streamOnce(body: body, reply: &reply, onText: onText, onActivity: onActivity)
            current += blocks
            // The inbox check comes before any tool handling: a contact_eli call ends the turn here, and the
            // text so far stays on screen (ChatSession keeps it).
            try await AnthropicClient.checkContact(body: body, response: ["content": blocks, "stop_reason": stop])
            if stop == "pause_turn" {
                if attempt == AnthropicClient.maxContinuations { throw APIError.badResponse("turn paused too many times") }
                log.notice("chat turn paused after a search; resuming")
                continue
            }
            if stop == "tool_use", let captureScreen {
                // The model called a client tool. Its turn so far is one assistant message; the results go
                // back as the next user message, and the turn continues in a new assistant message.
                let uses = blocks.filter { ($0["type"] as? String) == "tool_use" }
                guard !uses.isEmpty else { break }
                if attempt == AnthropicClient.maxContinuations { throw APIError.badResponse("turn used too many tool calls") }
                reply.transcript.append(["role": "assistant", "content": current])
                current = []
                var results: [[String: Any]] = []
                for use in uses {
                    results.append(await toolResult(for: use, reply: &reply, captureScreen: captureScreen))
                }
                reply.transcript.append(["role": "user", "content": results])
                continue
            }
            break
        }
        if !current.isEmpty { reply.transcript.append(["role": "assistant", "content": current]) }
        await onActivity(nil)
        let blocks = reply.blocks
        reply.searches = blocks.compactMap {
            ($0["type"] as? String) == "server_tool_use" ? ($0["input"] as? [String: Any])?["query"] as? String : nil
        }
        var seen = Set<String>()
        reply.sources = blocks.flatMap { ($0["citations"] as? [[String: Any]]) ?? [] }.compactMap { c in
            guard let url = c["url"] as? String, seen.insert(url).inserted else { return nil }
            return Source(title: (c["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url, url: url)
        }
        return reply
    }

    /// Runs one client tool call and builds its `tool_result` block. Failures go back to the model as error
    /// results rather than ending the reply, so it can say what happened.
    private func toolResult(for use: [String: Any], reply: inout ChatReply,
                            captureScreen: ScreenCaptureProvider) async -> [String: Any] {
        let id = use["id"] as? String ?? ""
        func failure(_ message: String) -> [String: Any] {
            ["type": "tool_result", "tool_use_id": id, "is_error": true, "content": message]
        }
        guard (use["name"] as? String) == AnthropicClient.captureToolName else {
            return failure("Unknown tool.")
        }
        guard reply.captures < AnthropicClient.maxCapturesPerReply else {
            return failure("Screenshot limit for this reply reached; answer with what you already have.")
        }
        do {
            let images = try await captureScreen()
            guard !images.isEmpty else { return failure("No displays found.") }
            reply.captures += 1
            log.notice("chat: model took a screenshot of \(images.count) display(s)")
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
            var content: [[String: Any]] = images.map(AnthropicClient.imageBlock)
            content.append(["type": "text", "text": "Screenshot(s) of \(images.count) display(s), captured \(f.string(from: Date())). Display N is image N in order. A gray box labeled \"hidden by Nosey\" marks a window that was deliberately left out; ignore it."])
            return ["type": "tool_result", "tool_use_id": id, "content": content]
        } catch {
            log.error("chat: screenshot for the model failed: \(error.localizedDescription, privacy: .public)")
            return failure("Screenshot failed: \(error.localizedDescription)")
        }
    }

    /// One streamed request. Content blocks are rebuilt from the events so they can be sent back verbatim.
    /// Returns the stop reason and this request's blocks.
    private func streamOnce(body: [String: Any], reply: inout ChatReply,
                            onText: @MainActor (String) -> Void,
                            onActivity: @MainActor (String?) -> Void) async throws -> (stop: String, blocks: [[String: Any]]) {
        let req = try request(body: body)
        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var buf = Data()
            for try await b in bytes { buf.append(b) }
            throw APIError.http(code, AnthropicClient.errorMessage(buf))
        }

        var stopReason = ""
        var blocks: [[String: Any]] = []      // this request's blocks, by stream index
        var partialJSON: [Int: String] = [:]  // tool input arrives as JSON fragments
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "message_start":
                if let msg = obj["message"] as? [String: Any] {
                    reply.usage.add(APIUsage(json: msg["usage"] as? [String: Any]))
                }
            case "content_block_start":
                guard let index = obj["index"] as? Int, var block = obj["content_block"] as? [String: Any] else { break }
                while blocks.count <= index { blocks.append([:]) }
                switch block["type"] as? String {
                case "text":
                    if block["text"] == nil { block["text"] = "" }
                    await onActivity(nil)
                case "server_tool_use":
                    // The input normally arrives as JSON fragments; a block that already carries it is kept as is.
                    if (block["input"] as? [String: Any])?.isEmpty ?? true { partialJSON[index] = "" }
                    if let q = (block["input"] as? [String: Any])?["query"] as? String {
                        await onActivity("Searching: \(q)")
                    } else {
                        await onActivity("Searching the web…")
                    }
                case "tool_use":
                    if (block["input"] as? [String: Any])?.isEmpty ?? true { partialJSON[index] = "" }
                    if (block["name"] as? String) == AnthropicClient.captureToolName {
                        await onActivity("Taking a screenshot…")
                    }
                default: break
                }
                blocks[index] = block
            case "content_block_delta":
                guard let index = obj["index"] as? Int, index < blocks.count,
                      let delta = obj["delta"] as? [String: Any] else { break }
                switch delta["type"] as? String {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    blocks[index]["text"] = (blocks[index]["text"] as? String ?? "") + text
                    reply.text += text
                    await onText(text)
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "citations_delta":
                    if let c = delta["citation"] as? [String: Any] {
                        blocks[index]["citations"] = (blocks[index]["citations"] as? [[String: Any]] ?? []) + [c]
                    }
                case "thinking_delta":
                    blocks[index]["thinking"] = (blocks[index]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    blocks[index]["signature"] = delta["signature"] as? String ?? ""
                default: break
                }
            case "content_block_stop":
                guard let index = obj["index"] as? Int, index < blocks.count else { break }
                if let raw = partialJSON.removeValue(forKey: index) {
                    // A tool call with no arguments can arrive with no fragments at all; it still needs `input`.
                    let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                    blocks[index]["input"] = input
                    if (blocks[index]["name"] as? String) == "web_search", let q = input["query"] as? String {
                        await onActivity("Searching: \(q)")
                    }
                }
            case "message_delta":
                if let u = obj["usage"] as? [String: Any] {
                    reply.usage.outputTokens = u["output_tokens"] as? Int ?? reply.usage.outputTokens
                    reply.usage.webSearches += APIUsage.searches(in: u)
                }
                if let d = obj["delta"] as? [String: Any], let s = d["stop_reason"] as? String {
                    stopReason = s
                    if s == "refusal" {
                        let note = "\n\n[The model declined to continue this response.]"
                        reply.text += note
                        await onText(note)
                    }
                }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                throw APIError.stream(msg)
            default:
                break
            }
        }
        return (stopReason, blocks.filter { !$0.isEmpty })
    }

    /// Cheap connectivity/key check. Even this carries the shared preamble and the contact_eli tool.
    func ping(model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model, "max_tokens": 64,
            "system": try LLMContact.systemPrompt(""),
            "tools": [try LLMContact.contactTool()],
            "messages": [["role": "user", "content": "Reply with the single word OK."]],
        ]
        let (data, resp) = try await session.data(for: try request(body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, AnthropicClient.errorMessage(data)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try await AnthropicClient.checkContact(body: body, response: json ?? [:])
        let blocks = json?["content"] as? [[String: Any]] ?? []
        return blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String ?? "(no text)"
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "unreadable body"
    }
}
