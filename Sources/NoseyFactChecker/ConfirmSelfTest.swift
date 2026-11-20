import Foundation

/// `--test-confirm`: an offline check of the contact_eli confirm step and of note_to_eli handling
/// (LLMContact.confirmedCheck) with stubbed model replies and the real `llm_contact.py`. It points the script at a throwaway inbox through
/// LLM_INBOX_DIR, so records land there and Eli is not notified. No network, no API key, no app startup.
enum ConfirmSelfTest {
    private struct Stubbed: Error {}

    static func run() async -> Bool {
        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("nosey-confirm-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // Before any llm_contact.py run: the child processes inherit it, and with it set the script neither
        // touches the real inbox nor sends a notification.
        setenv("LLM_INBOX_DIR", inbox.path, 1)
        FileLog.prefix = "[--test-confirm, stubbed] "
        print("test inbox: \(inbox.path)")

        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        func lines(_ name: String) -> [String] {
            let text = (try? String(contentsOf: inbox.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }

        // No request is made; the name matters because llm_contact.py only plans a question for the models
        // in its CONFIRM_MODELS list, and this one is on it.
        var model = "claude-haiku-4-5"
        let system = "stub system"
        let messages: [[String: Any]] = [["role": "user", "content": "SELF-TEST question"]]
        let tools: [[String: Any]] = (try? LLMContact.contactTools()) ?? [["name": "contact_eli"], ["name": "note_to_eli"]]
        expect(tools.compactMap { $0["name"] as? String } == ["contact_eli", "note_to_eli"], "both shared tools are offered")
        let plain: [String: Any] = ["content": [["type": "text", "text": "{\"findings\":[]}"]], "stop_reason": "end_turn"]
        let toolCall: [String: Any] = ["content": [
            ["type": "tool_use", "id": "toolu_selftest", "name": "contact_eli",
             "input": ["message": "SELF-TEST: this page has nothing to check"]],
        ], "stop_reason": "tool_use"]
        func decision(_ meant: String) -> [String: Any] {
            ["content": [["type": "tool_use", "id": "toolu_decision", "name": "contact_eli_decision", "input": ["meant": meant]]]]
        }
        // A failed follow-up after a note is the one thing confirmedCheck throws; `threw` records it.
        var threw = false
        func check(_ response: [String: Any], noteRounds: Int = LLMContact.maxNoteRounds,
                   _ call: ([[String: Any]], [String: Any]?) async throws -> [String: Any])
            async -> (contact: LLMContact.Contact?, kept: (messages: [[String: Any]], response: [String: Any])?, noteTurn: [[String: Any]]?) {
            threw = false
            do {
                return try await LLMContact.confirmedCheck(model: model, system: system, messages: messages, response: response,
                                                           tools: tools, noteRounds: noteRounds, call: call)
            } catch {
                threw = true
                return (nil, nil, nil)
            }
        }

        // 1. No tool call: nothing is asked, nothing is recorded.
        var calls = 0
        var r = await check(plain) { _, _ in calls += 1; throw Stubbed() }
        expect(r.contact == nil && r.kept == nil && calls == 0, "no tool call: untouched, no extra model call")
        expect(lines("messages.jsonl").isEmpty && lines("unconfirmed.jsonl").isEmpty, "no tool call: inbox empty")

        // 2. Tool call, "keep working", then a normal answer: not sent, first reply kept in unconfirmed.jsonl.
        var asked: [(messages: [[String: Any]], decision: [String: Any]?)] = []
        r = await check(toolCall) { m, d in
            asked.append((m, d))
            return d != nil ? decision("task_remark_keep_working") : plain
        }
        expect(r.contact == nil, "keep: not sent")
        expect(r.kept?.messages.count == 3 && (r.kept?.response["stop_reason"] as? String) == "end_turn",
               "keep: caller gets the longer exchange and the new reply")
        expect(asked.count == 2 && asked.first?.decision != nil && asked.last?.decision == nil
                && asked.first?.messages.count == 3, "keep: one question, then one normal call")
        let d = asked.first?.decision ?? [:]
        expect((d["tool_choice"] as? [String: Any])?["name"] as? String == "contact_eli_decision"
                && (d["tools"] as? [[String: Any]])?.count == 3 && d["max_tokens"] is Int,
               "keep: the question forces the decision tool")
        expect(lines("messages.jsonl").isEmpty, "keep: nothing in messages.jsonl")
        expect(lines("unconfirmed.jsonl").count == 1 && lines("unconfirmed.jsonl")[0].contains("nothing to check"),
               "keep: first reply's text is in unconfirmed.jsonl")

        // 3. Tool call, then "send": the original goes through check.
        calls = 0
        r = await check(toolCall) { _, d in calls += 1; return d != nil ? decision("send_to_eli_and_stop") : plain }
        expect(r.contact?.message.contains("nothing to check") == true && r.kept == nil && calls == 1,
               "send: recorded, task stops, no further call")
        expect(lines("messages.jsonl").count == 1, "send: one record in messages.jsonl")

        // 4. The question fails: the original is sent.
        r = await check(toolCall) { _, _ in throw Stubbed() }
        expect(r.contact != nil && r.kept == nil && lines("messages.jsonl").count == 2, "question fails: original sent")

        // 5. The question comes back without a choice: the original is sent.
        r = await check(toolCall) { _, _ in plain }
        expect(r.contact != nil && r.kept == nil && lines("messages.jsonl").count == 3, "no clear choice: original sent")

        // 6. "Keep working", but the follow-up call fails: the original is sent.
        r = await check(toolCall) { _, d in
            if d != nil { return decision("task_remark_keep_working") }
            throw Stubbed()
        }
        expect(r.contact != nil && r.kept == nil && lines("messages.jsonl").count == 4, "follow-up fails: original sent")

        // 7. An "@ELI:" line is deliberate text: sent without a question.
        calls = 0
        r = await check(["content": [["type": "text", "text": "@ELI: SELF-TEST marker line"]]]) { _, _ in calls += 1; throw Stubbed() }
        expect(r.contact != nil && calls == 0 && lines("messages.jsonl").count == 5, "@ELI: line: sent, never questioned")

        // 8. A model the confirm step is not validated for: its contact_eli call is sent without a question.
        model = "claude-haiku-5-5"
        calls = 0
        r = await check(toolCall) { _, _ in calls += 1; return decision("task_remark_keep_working") }
        expect(r.contact?.message.contains("nothing to check") == true && r.kept == nil && calls == 0
                && lines("messages.jsonl").count == 6, "model not on the shared list: sent, no question asked")
        model = "claude-haiku-4-5"
        expect(lines("unconfirmed.jsonl").count == 1, "unconfirmed.jsonl still has just the one note")

        // --- note_to_eli: recorded, answered, never stops the task. Model names below are not on the confirm list.
        model = "claude-haiku-5-5"
        func note(_ id: String, _ text: String) -> [String: Any] {
            ["content": [["type": "tool_use", "id": id, "name": "note_to_eli", "input": ["message": text]]],
             "stop_reason": "tool_use"]
        }
        func records() -> [[String: Any]] {
            lines("messages.jsonl").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func isNote(_ rec: [String: Any]?, _ text: String) -> Bool {
            rec?["via"] as? String == "note" && rec?["halts"] as? Bool == false && rec?["message"] as? String == text
        }
        func noteAnswer(_ turn: [[String: Any]]?, _ id: String) -> String? {
            ((turn?.last?["content"] as? [[String: Any]])?.first { ($0["tool_use_id"] as? String) == id })?["content"] as? String
        }

        // 10. A note-only reply: recorded once, answered, the model is asked again and its answer is the result.
        asked = []
        r = await check(note("toolu_note1", "SELF-TEST note one")) { m, d in asked.append((m, d)); return plain }
        expect(r.contact == nil && !threw, "note: task not stopped")
        expect(asked.count == 1 && asked[0].decision == nil && asked[0].messages.count == 3
                && noteAnswer(asked[0].messages, "toolu_note1")?.contains("carry on") == true,
               "note: one more normal call, with the note answered")
        expect(r.kept?.messages.count == 3 && (r.kept?.response["stop_reason"] as? String) == "end_turn" && r.noteTurn == nil,
               "note: caller gets the longer exchange and the normal answer")
        expect(records().count == 7 && isNote(records().last, "SELF-TEST note one"),
               "note: one record, via note, halts false")

        // 11. A note, then a reply that calls contact_eli: the note is recorded and the task still stops.
        calls = 0
        r = await check(note("toolu_note2", "SELF-TEST note two")) { _, _ in calls += 1; return toolCall }
        expect(r.contact?.message.contains("nothing to check") == true && calls == 1 && records().count == 9
                && isNote(records()[7], "SELF-TEST note two") && records()[8]["via"] as? String == "tool",
               "note then contact_eli: both recorded, task stops")

        // 12. contact_eli and a note in one reply: both recorded, task stops, the model is not asked again.
        calls = 0
        let both: [String: Any] = ["content": (note("toolu_note3", "SELF-TEST note three")["content"] as? [[String: Any]] ?? [])
            + (toolCall["content"] as? [[String: Any]] ?? []), "stop_reason": "tool_use"]
        r = await check(both) { _, _ in calls += 1; return plain }
        expect(r.contact != nil && r.kept == nil && calls == 0 && records().count == 11, "note + contact_eli together: stops")

        // 13. The model keeps leaving notes: asked again at most maxNoteRounds times, each note recorded once, no stop.
        calls = 0
        r = await check(note("toolu_note4", "SELF-TEST note four")) { _, _ in calls += 1; return note("toolu_note4", "SELF-TEST note four") }
        expect(r.contact == nil && !threw && calls == LLMContact.maxNoteRounds && records().count == 11 + 1 + LLMContact.maxNoteRounds,
               "notes every time: capped at \(LLMContact.maxNoteRounds) follow-ups, no stop")
        var n = records().count

        // 14. The follow-up request fails: thrown like any failed request, not a stop; the note is already recorded.
        r = await check(note("toolu_note5", "SELF-TEST note five")) { _, _ in throw Stubbed() }
        expect(threw && r.contact == nil && records().count == n + 1 && isNote(records().last, "SELF-TEST note five"),
               "note, then the follow-up fails: error, not a stop; note kept")
        n += 1

        // 15. A caller with its own tool loop (the chat): no follow-up call here, it answers the note itself.
        calls = 0
        r = await check(note("toolu_note6", "SELF-TEST note six"), noteRounds: 0) { _, _ in calls += 1; return plain }
        let answer = AnthropicClient.noteResult(id: "toolu_note6", noteTurn: r.noteTurn)
        expect(r.contact == nil && r.kept == nil && calls == 0 && records().count == n + 1
                && (answer["content"] as? String)?.contains("carry on") == true && answer["is_error"] == nil,
               "tool loop: note recorded once, acknowledgement returned as the tool result, no stop")
        expect(AnthropicClient.noteResult(id: "toolu_x", noteTurn: nil)["is_error"] as? Bool == true,
               "tool loop: a note the check did not record is not reported as delivered")
        model = "claude-haiku-4-5"
        expect(lines("unconfirmed.jsonl").count == 1, "notes never go to unconfirmed.jsonl")

        // 16. The question's request drops what the API rejects with a forced tool choice.
        let body: [String: Any] = ["model": model, "system": system, "max_tokens": 4096, "stream": true,
                                   "thinking": ["type": "adaptive"], "tools": tools, "messages": messages,
                                   "output_config": ["effort": "low", "format": ["type": "json_schema"]]]
        let q = AnthropicClient.decisionBody(from: body, messages: messages + messages, decision: d)
        expect(q["thinking"] == nil && q["output_config"] == nil && q["stream"] == nil && q["tool_choice"] != nil
                && (q["tools"] as? [[String: Any]])?.count == 3 && (q["messages"] as? [[String: Any]])?.count == 2
                && q["max_tokens"] as? Int == d["max_tokens"] as? Int && q["model"] as? String == model
                && q["system"] as? String == system,
               "question request: same model and system, no thinking, no output format, not streamed")

        print(failures == 0 ? "PASS" : "FAILED (\(failures))")
        return failures == 0
    }
}
