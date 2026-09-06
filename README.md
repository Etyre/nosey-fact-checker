# Nosey

A menu bar app for macOS that watches your screen and flags statements that are false or
misleading, using Claude. When it spots something, a normal macOS notification appears in the
top right with a one-line summary. Press the hotkey (default **⌥⌘J**: modifiers under the left hand, letter under the right) to open a streaming chat
window about the finding, ask questions, or push back. Press the hotkey again (or Esc) to close it.

## How it works

1. Every N seconds (default 5) it captures every connected display with ScreenCaptureKit,
   downscaled to 1568 px on the long edge and JPEG-encoded. Its own windows are excluded.
2. It compares a 32×32 thumbnail against the previous capture. If the screen has not changed
   enough (default 1% of cells), nothing is sent. This is the main cost control.
3. Changed captures are saved to `~/Library/Application Support/Nosey/captures/` (pruned after
   24 h by default) and sent to Claude (`claude-sonnet-5` by default) with your fact-check
   prompt. The reply is structured JSON: a list of findings, each with claim, summary,
   explanation, confidence, and display number.
4. Findings below your confidence threshold, or similar to something already flagged in the
   last 24 h, are dropped. The rest become notifications (at most 3 per check).
5. The chat window seeds the conversation with the screenshot(s) and the finding, so the model
   can discuss exactly what it saw. Replies stream token by token. The input field is focused
   automatically.

## Build and run

Requires Xcode 26 (or its command line tools) on macOS 14 or later.

```bash
./build.sh --run              # build build/Nosey.app and launch it
./build.sh --install --run    # also copy to ~/Applications (needed for Launch at Login)
```

The script signs with your Apple Development certificate if one is in the keychain, so the
Screen Recording grant survives rebuilds. Without one it falls back to ad-hoc signing, and
macOS will ask for Screen Recording again after each rebuild.

## First launch

1. **Screen Recording**: macOS prompts once. Grant it in System Settings › Privacy & Security
   › Screen Recording, then quit and relaunch Nosey (macOS requires a relaunch).
2. **Notifications**: allow when asked. If you missed the prompt, Settings › Notification
   settings… opens the right pane.
3. **API key**: Settings opens automatically when no key is stored. Paste your Anthropic API key
   and click Save (or Test). The key is written to
   `~/Library/Application Support/Nosey/api-key` with permissions 0600. `ANTHROPIC_API_KEY` in
   the environment is used as a fallback when launched from a shell.
   If the key is identity-linked (the API replies that `anthropic-workspace-id` is required),
   also paste the workspace ID (`wrkspc_…`, from Console › Settings › Workspaces) into the
   Workspace ID field.

## Menu bar

- **nose** icon: watching. **nose with a dot**: there are unread flags. **outlined nose with a slash**: paused or a
  problem (the first menu line says which).
- Open Chat, Check Screen Now, Pause / Pause for 1 Hour / Resume, Recent Flags (click one to
  discuss it), today's usage estimate, Settings, Show Captures Folder, Quit.

## Chat window

- Hotkey toggles it. Esc or ⌘W hides it. Focus returns to the app you were using.
- ⌘1 / ⌘2 / ⌘3 switch between quarter (top right), half (right half), and full screen sizes.
- The conversation menu at the top lists recent flags and lets you start a free chat.
- The camera button attaches a fresh screenshot of all displays to your next message.

## Tuning

Everything lives in Settings:

- **Prompts tab**: edit the fact-check system prompt to teach it what is and isn't worth
  flagging, and the chat prompt for how it should argue. Reset buttons restore the defaults.
- **Interval, change threshold, confidence threshold, retention**: cost and noise controls.
- **Model and effort**: any current Claude model ID works. Effort `low` is the default for
  background checks; chat uses at least `medium`.
- **Hotkeys**: text like `alt+cmd+j`, `shift+cmd+space`, `ctrl+alt+f9`. The dismiss hotkey (default `alt+cmd+k`) clears Nosey's notifications; set the alert style to Alerts in System Settings if you want them to stay until dismissed.

## Cost

A single 1568×882 screenshot is about 1,850 input tokens. With Sonnet 5 at $2 per million
input tokens, one check with one display costs roughly $0.004 plus a fraction of a cent of
output. If the screen changed on every 5-second tick for an hour that would be about $3; in
practice change detection skips most ticks while you read or think. Two displays roughly
double it. The menu shows a running estimate for today; the Anthropic Console has the real
figure. Pause for 1 Hour is there for meetings and video.

## Files

- `Sources/NoseyFactChecker/` – Swift sources (SwiftUI + AppKit, no third-party dependencies)
- `Resources/Info.plist` – bundle metadata (`LSUIElement` keeps it out of the Dock)
- `build.sh` – builds, bundles, and signs `build/Nosey.app`
- Data: `~/Library/Application Support/Nosey/` (captures, findings.json, api-key)
- Logs: Console.app, subsystem `com.elityre.nosey`
