import Foundation
import os

private let log = Logger(subsystem: "com.elityre.nosey", category: "api")

enum APIError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse(String)
    case stream(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "No API key. Open Settings and paste your Anthropic API key."
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

/// Raw-HTTP client for the Claude Messages API (there is no official Swift SDK).
final class AnthropicClient {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

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
        return m.contains("sonnet-5") || m.contains("opus-5") || m.contains("fable") || m.contains("mythos")
            || m.contains("opus-4-6") || m.contains("opus-4-7") || m.contains("opus-4-8") || m.contains("sonnet-4-6")
    }

    private static func baseBody(model: String, effort: String, system: String, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
        ]
        if supportsAdaptive(model) {
            body["thinking"] = ["type": "adaptive"]
            body["output_config"] = ["effort": effort]
        }
        return body
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

    func factCheck(model: String, effort: String, system: String, images: [Data], userText: String) async throws -> ([RawFinding], APIUsage) {
        var body = AnthropicClient.baseBody(model: model, effort: effort, system: system, maxTokens: 2048)
        var outputConfig = body["output_config"] as? [String: Any] ?? [:]
        outputConfig["format"] = ["type": "json_schema", "schema": AnthropicClient.findingsSchema]
        body["output_config"] = outputConfig
        var content: [[String: Any]] = images.map(AnthropicClient.imageBlock)
        content.append(["type": "text", "text": userText])
        body["messages"] = [["role": "user", "content": content]]

        let req = try request(body: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, AnthropicClient.errorMessage(data)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse("not a JSON object")
        }
        let usage = APIUsage(json: json["usage"] as? [String: Any])
        let stopReason = json["stop_reason"] as? String ?? ""
        if stopReason == "refusal" {
            log.notice("fact-check refused by safety classifier; treating as no findings")
            return ([], usage)
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw APIError.badResponse("no text block (stop_reason=\(stopReason))")
        }
        let decoded = try JSONDecoder().decode(FactCheckResponse.self, from: Data(text.utf8))
        return (decoded.findings, usage)
    }

    // MARK: Chat (streaming SSE)

    /// Streams a reply. `onText` is called on the main actor for each text delta. Returns the full text.
    func streamChat(model: String, effort: String, system: String, messages: [[String: Any]],
                    onText: @escaping @MainActor (String) -> Void) async throws -> (String, APIUsage) {
        var body = AnthropicClient.baseBody(model: model, effort: effort, system: system, maxTokens: 8192)
        body["stream"] = true
        body["messages"] = messages
        let req = try request(body: body)

        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var buf = Data()
            for try await b in bytes { buf.append(b) }
            throw APIError.http(code, AnthropicClient.errorMessage(buf))
        }

        var full = ""
        var usage = APIUsage()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   (delta["type"] as? String) == "text_delta",
                   let text = delta["text"] as? String {
                    full += text
                    await onText(text)
                }
            case "message_start":
                if let msg = obj["message"] as? [String: Any] {
                    usage.add(APIUsage(json: msg["usage"] as? [String: Any]))
                }
            case "message_delta":
                if let u = obj["usage"] as? [String: Any] {
                    usage.outputTokens = u["output_tokens"] as? Int ?? usage.outputTokens
                }
                if let d = obj["delta"] as? [String: Any], (d["stop_reason"] as? String) == "refusal" {
                    full += "\n\n[The model declined to continue this response.]"
                    await onText("\n\n[The model declined to continue this response.]")
                }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                throw APIError.stream(msg)
            default:
                break
            }
        }
        return (full, usage)
    }

    /// Cheap connectivity/key check.
    func ping(model: String) async throws -> String {
        let body: [String: Any] = [
            "model": model, "max_tokens": 32,
            "messages": [["role": "user", "content": "Reply with the single word OK."]],
        ]
        let (data, resp) = try await session.data(for: try request(body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, AnthropicClient.errorMessage(data)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
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
