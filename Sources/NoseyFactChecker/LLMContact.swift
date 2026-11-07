import Foundation
import os

private let log = Logger(subsystem: "com.elityre.nosey", category: "llm-contact")

/// The shared LLM inbox (~/Documents/agent-coding/shared, see its README). Every system prompt Nosey sends
/// starts with the shared preamble, every request offers the `contact_eli` tool, and every response is run
/// through `llm_contact.py check`, which records a message to Eli and notifies him. When it does, the task
/// that produced the response stops: a background check pauses watching, a chat is closed to further turns.
/// The preamble and tool definition are read from disk on every request so edits there apply at once.
enum LLMContact {
    static let app = "nosey"
    static let sharedDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/agent-coding/shared", isDirectory: true)
    static let preambleURL = sharedDir.appendingPathComponent("llm-system-prompt-preamble.md")
    static let toolURL = sharedDir.appendingPathComponent("contact_eli_tool.json")
    static let scriptURL = sharedDir.appendingPathComponent("llm_contact.py")

    /// A message the model sent to Eli, as recorded by the inbox.
    struct Contact {
        let id: String
        let message: String
    }

    enum Failure: LocalizedError {
        case missing(URL)
        var errorDescription: String? {
            switch self {
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

    /// The `contact_eli` tool definition, ready to go in a request's `tools` array.
    static func contactTool() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: toolURL),
              let tool = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              tool["name"] is String else {
            throw Failure.missing(toolURL)
        }
        return tool
    }

    /// Runs `llm_contact.py check` on one response. Returns the recorded contact when the model called
    /// `contact_eli` or wrote an `@ELI:` line, else nil. A failure to run the check is logged, not thrown:
    /// the inbox must not take Nosey down with it.
    static func check(model: String, system: String, messages: [[String: Any]], response: [String: Any],
                      tools: [[String: Any]]) async -> Contact? {
        let payload: [String: Any] = ["app": app, "model": model, "system": system, "messages": messages,
                                      "response": response, "tools": tools]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            fail("could not encode the check payload")
            return nil
        }
        return await Task.detached(priority: .utility) { run(payload: data) }.value
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

    private static func run(payload: Data) -> Contact? {
        guard let python else { fail("no python3 found for llm_contact.py"); return nil }
        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else { fail("missing \(scriptURL.path)"); return nil }
        let proc = Process()
        proc.executableURL = python
        proc.arguments = [scriptURL.path, "check"]
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
        switch proc.terminationStatus {
        case 0:
            return nil
        case 3:
            // The last JSON line is the record summary; anything before it is a warning from the script.
            let line = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
            let rec = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
            let contact = Contact(id: rec["id"] as? String ?? "?", message: rec["message"] as? String ?? out)
            FileLog.write("model contacted Eli (inbox \(contact.id)): \(contact.message.prefix(300))")
            log.notice("model contacted Eli, inbox record \(contact.id, privacy: .public)")
            return contact
        default:
            fail("llm_contact.py check exited \(proc.terminationStatus): \(out.suffix(500))")
            return nil
        }
    }

    private static func fail(_ message: String) {
        FileLog.write("LLM inbox check FAILED: \(message)")
        log.error("inbox check failed: \(message, privacy: .public)")
    }
}
