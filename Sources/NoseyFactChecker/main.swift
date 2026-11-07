// Nosey: a macOS menu bar app that screenshots every display every few seconds, sends changed screens to
// Claude to spot false or misleading statements, and shows each one as a notification you can discuss in
// a chat window (hotkey ctrl+cmd+j by default). Entry point; the app lives in AppDelegate.
//
// Settings:  UserDefaults (com.elityre.nosey), edited in the Settings window
// API key:   ~/Library/Application Support/Nosey/api-key (0600), or ANTHROPIC_API_KEY when run from a shell
// Data:      ~/Library/Application Support/Nosey/ (captures/, findings.json, misfires.json)
// Log:       ~/Library/Logs/nosey.log (also os_log subsystem com.elityre.nosey)
// LLM inbox: every prompt starts with ~/Documents/agent-coding/shared/llm-system-prompt-preamble.md and every
//            response is checked by shared/llm_contact.py; see LLMContact.swift.
import AppKit

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
