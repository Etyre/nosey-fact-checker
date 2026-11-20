import Foundation
import os

private let log = Logger(subsystem: "com.elityre.nosey", category: "llm-contact")

/// The shared LLM inbox (~/Documents/agent-coding/shared, see its README). Every system prompt Nosey sends
/// starts with the shared preamble, every request offers the `contact_eli` and `note_to_eli` tools, and every
/// response is run through `llm_contact.py check`, which records a message to Eli and notifies him (a
/// `contact_eli` call first goes through the confirm step, `confirmedCheck`). When it does, the task
/// that produced the response stops: a background check pauses watching, a chat is closed to further turns.
/// A `note_to_eli` call is recorded by the same check but stops nothing: the call is answered and the task
/// carries on (`confirmedCheck` asks again; the chat's tool loop answers it like any other tool).
/// The preamble and tool definitions are read from disk on every request so edits there apply at once.
enum LLMContact {
    static let app = "nosey"
    static let sharedDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/agent-coding/shared", isDirectory: true)
    static let preambleURL = sharedDir.appendingPathComponent("llm-system-prompt-preamble.md")
    static let toolURL = sharedDir.appendingPathComponent("contact_eli_tool.json")
    static let noteToolURL = sharedDir.appendingPathComponent("note_to_eli_tool.json")
    static let noteToolName = "note_to_eli"
    /// How many times in a row a reply that only leaves notes is answered and asked again (as shared with_notes).
    static let maxNoteRounds = 3
    static let scriptURL = sharedDir.appendingPathComponent("llm_contact.py")

    /// A message the model sent to Eli, as recorded by the inbox.
    struct Contact {
        let id: String
        let message: String
    }

    enum Failure: LocalizedError {
        case missing(URL)
        case badPlan
        var errorDescription: String? {
            switch self {
            case .badPlan: return "llm_contact.py confirm returned an unexpected shape"
            case .missing(let url): return "Shared LLM inbox file is missing or unreadable: \(url.path)"
            }
        }
    }

    /// The preamble text, word for word, from the shared file.
    static func preamble() throws -> String {
        guard let text = try? String(contentsOf: preambleURL, encoding: .utf8), !text.isEmpty else {
            throw Failure.missing(preambleURL)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The shared preamble followed by Nosey's own instructions.
    static func systemPrompt(_ instructions: String) throws -> String {
        let own = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return try preamble() + (own.isEmpty ? "" : "\n\n" + own)
    }

    /// The `contact_eli` (stops the task) and `note_to_eli` (task carries on) tool definitions, ready to go
    /// in a request's `tools` array. Every request that offers one offers both.
    static func contactTools() throws -> [[String: Any]] {
        try [toolURL, noteToolURL].map { url in
            guard let data = try? Data(contentsOf: url),
                  let tool = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  tool["name"] is String else {
                throw Failure.missing(url)
            }
            return tool
        }
    }

    /// Runs `llm_contact.py check` on one response. `contact` is the recorded contact when the model called
    /// `contact_eli` or wrote an `@ELI:` line, else nil. `noteTurn` is set when the response only left notes
    /// (`note_to_eli`): the check has recorded them, and these are the two messages that answer the calls (the
    /// model's own turn, then the tool results). A failure to run the check is logged, not thrown: the inbox
    /// must not take Nosey down with it.
    static func check(model: String, system: String, messages: [[String: Any]], response: [String: Any],
                      tools: [[String: Any]]) async -> (contact: Contact?, noteTurn: [[String: Any]]?) {
        let payload: [String: Any] = ["app": app, "model": model, "system": system, "messages": messages,
                                      "response": response, "tools": tools]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            fail("could not encode the check payload")
            return (nil, nil)
        }
        return await Task.detached(priority: .utility) { runCheck(payload: data) }.value
    }

    /// The confirm step followed by `check` (shared README, "Confirm step in any other language"). Small models
    /// use `contact_eli` for routine remarks about the task, so a call to it is followed by one forced-choice
    /// question before anything is sent. `call(messages, decision)` makes the app's model call on a longer
    /// message list: with `decision` nil exactly as the original call, otherwise as the question (see
    /// `AnthropicClient.decisionBody`). Sending is the default: only an explicit "keep working" answer continues
    /// the task, and any error or unexpected shape in the confirm step ends in `check` on the original response,
    /// so a broken confirm step cannot lose a message. `kept` is set when the task went on past the first
    /// response: the continued messages and the model's new reply, which the caller carries on with (unless
    /// `contact` is set, when the new reply contacted Eli).
    ///
    /// Notes: a response that only leaves `note_to_eli` notes never stops the task. `check` has recorded them;
    /// the calls are answered and the model is asked again, up to `noteRounds` times, and each new reply goes
    /// through this whole function again. If that follow-up request fails the error is thrown like any failed
    /// request (the note is already recorded). A caller with its own tool loop passes `noteRounds: 0` and
    /// answers the calls itself from `noteTurn`, which is the answer to the notes in the response it carries
    /// on with.
    static func confirmedCheck(model: String, system: String, messages: [[String: Any]], response: [String: Any],
                               tools: [[String: Any]], noteRounds: Int = maxNoteRounds,
                               call: (_ messages: [[String: Any]], _ decision: [String: Any]?) async throws -> [String: Any])
        async throws -> (contact: Contact?, kept: (messages: [[String: Any]], response: [String: Any])?, noteTurn: [[String: Any]]?) {
        var kept: (messages: [[String: Any]], response: [String: Any])?
        // nil for a response without a contact_eli call, an "@ELI:" line included: that is never questioned.
        if let plan = await confirmPlan(model: model, response: response, tools: tools) {
            do {
                guard let ask = plan["ask"] as? [[String: Any]], let keep = plan["keep"] as? [[String: Any]],
                      let decision = plan["decision"] as? [String: Any],
                      let toolName = plan["decision_tool_name"] as? String,
                      let keepValue = plan["keep_value"] as? String, !keepValue.isEmpty else {
                    throw Failure.badPlan
                }
                let answer = try await call(messages + ask, decision)
                let choice = (answer["content"] as? [[String: Any]] ?? [])
                    .first { ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName }
                if (choice?["input"] as? [String: Any])?["meant"] as? String == keepValue {
                    let continued = messages + keep
                    kept = (continued, try await call(continued, nil))
                }
            } catch {
                fail("confirm step failed, sending the original message: \(error.localizedDescription)")
            }
        }
        let checked = await check(model: model, system: system, messages: kept?.messages ?? messages,
                                  response: kept?.response ?? response, tools: tools)
        if kept != nil, checked.contact == nil {
            // Nothing is discarded: what the model said the first time goes to unconfirmed.jsonl.
            await noteUnconfirmed(model: model, response: response)
            FileLog.write("contact_eli call was a task remark (model's choice); not sent, task continues")
        }
        if checked.contact == nil, let turn = checked.noteTurn, noteRounds > 0 {
            let longer = (kept?.messages ?? messages) + turn
            let next = try await call(longer, nil)
            let r = try await confirmedCheck(model: model, system: system, messages: longer, response: next,
                                             tools: tools, noteRounds: noteRounds - 1, call: call)
            return (r.contact, r.kept ?? (longer, next), r.noteTurn)
        }
        return (checked.contact, kept, checked.noteTurn)
    }

    /// `llm_contact.py confirm`: nil when the response has no `contact_eli` call, the model is not one the shared
    /// confirm step is validated for (it decides from `model`), or the script could not say,
    /// else the messages and request arguments for the question.
    private static func confirmPlan(model: String, response: [String: Any], tools: [[String: Any]]) async -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["model": model, "response": response, "tools": tools]) else { return nil }
        return await Task.detached(priority: .utility) { () -> [String: Any]? in
            guard let (status, out) = run("confirm", payload: data) else { return nil }
            guard status == 0 else { fail("llm_contact.py confirm exited \(status): \(out.suffix(500))"); return nil }
            let line = out.split(separator: "\n").last.map(String.init) ?? ""
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]   // "null" gives nil
        }.value
    }

    /// `llm_contact.py unconfirmed`: keeps the text of a `contact_eli` call the model chose not to send.
    private static func noteUnconfirmed(model: String, response: [String: Any]) async {
        let payload: [String: Any] = ["app": app, "model": model, "response": response]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        await Task.detached(priority: .utility) {
            if let (status, out) = run("unconfirmed", payload: data), status != 0 {
                fail("llm_contact.py unconfirmed exited \(status): \(out.suffix(500))")
            }
        }.value
    }

    /// The first interpreter that exists. The system python3 (3.9) is too old for llm_contact.py, so it is
    /// the last resort; the shared venv is preferred because `llm-inbox` itself runs in it.
    private static var python: URL? {
        let candidates = [
            sharedDir.appendingPathComponent(".venv/bin/python3").path,
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Runs one `llm_contact.py` command with the payload on stdin. Returns its exit status and output, or nil
    /// (logged) when it could not be started.
    private static func run(_ command: String, payload: Data) -> (status: Int32, out: String)? {
        guard let python else { fail("no python3 found for llm_contact.py"); return nil }
        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else { fail("missing \(scriptURL.path)"); return nil }
        let proc = Process()
        proc.executableURL = python
        proc.arguments = [scriptURL.path, command]
        proc.currentDirectoryURL = sharedDir
        let stdin = Pipe(), output = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = output
        proc.standardError = output   // one pipe, one reader: no deadlock whichever side fills first
        do { try proc.run() } catch {
            fail("could not start \(python.path): \(error.localizedDescription)")
            return nil
        }
        // The payload (screenshots included) is far bigger than a pipe buffer, so it is written on its own
        // thread while this one drains the output.
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: payload)
            try? stdin.fileHandleForWriting.close()
        }
        // Recording a contact pushes to ntfy, email and a Mac notification, each with its own network timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if proc.isRunning { proc.terminate() } }
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        return (proc.terminationStatus, out)
    }

    private static func runCheck(payload: Data) -> (contact: Contact?, noteTurn: [[String: Any]]?) {
        guard let (status, out) = run("check", payload: payload) else { return (nil, nil) }
        // The last JSON line is the script's answer; anything before it is a warning from the script.
        let line = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
        let rec = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
        switch status {
        case 0:
            // Nothing printed: a plain response. {"halts": false, "notes", "continue"}: notes only, recorded.
            guard let turn = rec["continue"] as? [[String: Any]] else { return (nil, nil) }
            let notes = (rec["notes"] as? [String] ?? []).joined(separator: " | ")
            FileLog.write("model left Eli a note (recorded in the inbox, task continues): \(notes.prefix(300))")
            log.notice("model left Eli a note; task continues")
            return (nil, turn)
        case 3:
            let contact = Contact(id: rec["id"] as? String ?? "?", message: rec["message"] as? String ?? out)
            FileLog.write("model contacted Eli (inbox \(contact.id)): \(contact.message.prefix(300))")
            log.notice("model contacted Eli, inbox record \(contact.id, privacy: .public)")
            return (contact, nil)
        default:
            fail("llm_contact.py check exited \(status): \(out.suffix(500))")
            return (nil, nil)
        }
    }

    private static func fail(_ message: String) {
        FileLog.write("LLM inbox check FAILED: \(message)")
        log.error("inbox check failed: \(message, privacy: .public)")
    }
}
