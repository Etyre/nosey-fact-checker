# Nosey

A menu bar app for macOS that watches your screen and flags statements that are false or
misleading, using Claude. When it spots something, a normal macOS notification appears in the
top right with a one-line summary. Press the hotkey (default **⌃⌘J**: modifiers under the left hand,
letter under the right) to open a streaming chat window about the finding, ask questions, or push
back. Press the hotkey again (or Esc) to close it. Built 2026-09-02 as a quiet background
fact-checker: it should interrupt only for a concrete, checkable claim that is wrong, and stay
silent otherwise. Swift (SwiftUI + AppKit), no third-party dependencies.

## How it works

1. Every N seconds (default 5) it captures every connected display with ScreenCaptureKit,
   downscaled to 1568 px on the long edge and JPEG-encoded. Its own windows are excluded, as
   are the windows of any app on the privacy list in Settings (Signal by default). Each excluded
   window's area is painted over with a gray box labeled "<App> window hidden by Nosey", so the
   gap is obvious to anyone looking at the capture later, and the model is told to ignore it.
2. It compares a 64×64 thumbnail against the last capture that was actually sent. A big
   change (default 1% of cells: a window switch, scrolling, a large edit) is sent at once. A
   minor one such as a typed sentence (default 0.3% of cells) is held until the screen has
   been still for two ticks, then sent once. Anything smaller, like the blinking caret or the
   menu bar clock, is ignored. This is the main cost control.
3. Changed captures are saved to `~/Library/Application Support/Nosey/captures/` (pruned after
   24 h by default) and sent to Claude (`claude-haiku-5-5` by default) with your fact-check
   prompt. The reply is structured JSON: a list of findings, each with claim, summary,
   explanation, confidence, and display number. The model has Anthropic's server-side web
   search tool (on by default, capped at 2 searches per check) so it can verify a claim before
   flagging it, including claims about things after its training cutoff.
4. Findings below your confidence threshold, or similar to something already flagged in the
   last 24 h, are dropped, as is anything matching a known misfire (below). The rest become
   notifications (at most 3 per check).
5. The chat window seeds the conversation with the screenshot(s) and the finding, so the model
   can discuss exactly what it saw. Replies stream token by token; when the model searches the
   web, the queries show while it runs and the cited pages are listed under the reply as links.
   The model also has a `capture_screen` tool: when you refer to what is on screen now, or ask
   it to look again, it can take a fresh screenshot of every display mid-reply (at most 3 per
   reply) and answer from that. The reply then shows "Took a fresh screenshot". The input field
   is focused automatically.
6. If, while discussing a flag, the model concludes it was wrong, it ends that reply with a
   `RETRACTED: <reason>` line. Nosey strips the line, shows "Flag withdrawn" under the reply,
   and adds the claim to a persistent misfire list (`misfires.json`). The "Not an error" button
   on the flag card does the same by hand. Every later check is sent the misfire list with an
   instruction never to flag those claims again, and any candidate that still matches one is
   dropped before it can become a notification. Settings lists the misfires and lets you
   remove one if you change your mind. Both lists ride in the cached part of the system prompt,
   so they are read at a tenth of the input rate on every check and only re-billed in full when
   a flag is added or withdrawn.
7. **LLM inbox** (shared with every project here, see `../shared/README.md`). Every system
   prompt, for checks, chat and the Settings "Test" ping alike, starts with the text of
   `~/Documents/agent-coding/shared/llm-system-prompt-preamble.md`, read from disk on each
   request, followed by Nosey's own prompt. Every request also offers the `contact_eli` tool
   from `shared/contact_eli_tool.json`. After every response Nosey pipes
   `{app, model, system, messages, response, tools}` to
   `python3 shared/llm_contact.py check` (`LLMContact.swift`). Exit 3 means the model called
   `contact_eli` or wrote an `@ELI:` line: the inbox has recorded the full context and notified
   Eli, and Nosey stops that task. A background check that does this pauses watching (the menu
   says why; Resume Watching continues). A chat reply that does this keeps the words already on
   screen, adds a note, and closes the conversation to further turns. Eli reads and continues
   it with `llm-inbox`. A missing preamble or tool file fails the request with a clear error
   rather than sending a prompt without the preamble; a failure to run the Python check is
   logged and does not stop Nosey.

### Menu bar

- **nose** icon: watching. **nose with a dot**: there are unread flags. **outlined nose with a slash**: paused or a
  problem (the first menu line says which).
- Open Chat, Check Screen Now, Dismiss Top / All Notifications, Send a Test Notification,
  Pause / Pause for 1 Hour / Resume, Recent Flags (click one to discuss it), today's usage
  estimate, Settings, Show Captures Folder, Open Log File, Quit.

### Chat window

- Hotkey toggles it. Esc or ⌘W hides it. Focus returns to the app you were using.
- ⌘1 / ⌘2 / ⌘3 switch between quarter (top right), half (right half), and full screen sizes.
- The conversation menu at the top lists recent flags and lets you start a free chat.
- The camera button attaches a fresh screenshot of all displays to your next message. The model
  can also take one itself with its `capture_screen` tool when the conversation calls for it.
- Whatever you have typed but not sent is saved as you type (UserDefaults, keyed by the flag
  the conversation is about; free chats share one draft) and comes back when you return to
  that conversation, reopen the window, or relaunch Nosey. A send that fails puts the text
  back. The same goes for the hotkey and bundle-ID fields in Settings until you press Apply or
  Add; the API key field is the one exception, being a secret.

### Tuning

Everything lives in Settings:

- **Prompts tab**: edit the fact-check system prompt to teach it what is and isn't worth
  flagging, and the chat prompt for how it should argue. Reset buttons restore the defaults.
  The shared preamble is prepended automatically and is not part of the editable text.
- **Interval, change and minor-edit thresholds, settle delay, confidence threshold, retention**: cost and noise controls.
- **Privacy**: apps whose windows are left out of every screenshot (Signal by default).
- **Misfires**: the claims whose flags were withdrawn; remove one to allow it to be flagged again.
- **Web search**: on/off, plus caps per background check and per chat reply. Searches cost
  $10 per 1,000 on top of tokens, and each one's results add roughly 10–20K input tokens.
  Set the per-check cap to 0 to keep search for chat only.
- **Models and effort**: background checks and chat each have their own model. Checks default
  to `claude-haiku-5-5` (they run every few seconds, and Haiku is about 20× cheaper than Sonnet
  per token); chat defaults to `claude-sonnet-5`. Any current Claude model ID works in either.
  Effort `low` is the default for background checks; chat uses at least `medium`.
- **Hotkeys**: text like `ctrl+cmd+j`, `shift+cmd+space`, `ctrl+alt+f9`. The dismiss hotkey (default `ctrl+cmd+k`) clears the top Nosey notification, one per press; the chat hotkey opens the top one; set the alert style to Alerts in System Settings if you want them to stay until dismissed.

### Cost

A single 1568×882 screenshot is about 1,850 input tokens, and a whole check with one display
is about 2,900 uncached input tokens. A check that flags nothing returns `{"findings":[]}`,
about 10 output tokens, so input is nearly the whole cost. With Haiku 5.5 at $0.10 per million
input tokens that is roughly $0.0003 per check, or about $0.20 if the screen changed on every
5-second tick for an hour; on Sonnet 5 ($2 per million) the same hour would be about $4. In
practice change detection skips most ticks while you read or think. Two displays roughly
double it. The menu shows a running estimate for today, priced per model; the Anthropic
Console has the real figure. Pause for 1 Hour is there for meetings and video.

### One copy at a time

Once a copy is installed in `~/Applications`, `./build.sh --run` updates and launches that copy
rather than the one in `build/`. macOS distinguishes apps by path, so two copies could otherwise
run side by side, each sending every screen change to Claude. The app also quits at startup if
another Nosey is already running, and re-registers Launch at Login from the installed copy.

## Files

| File | Purpose |
|---|---|
| `Sources/NoseyFactChecker/main.swift` | Entry point; header comment with the runtime locations |
| `Sources/NoseyFactChecker/AppDelegate.swift` | Menu bar item and menu, hotkeys, single-instance check, Launch at Login |
| `Sources/NoseyFactChecker/FactCheckEngine.swift` | The capture → change-detect → fact-check → notify loop; `FileLog` |
| `Sources/NoseyFactChecker/ScreenCapturer.swift` | ScreenCaptureKit capture of every display, privacy boxes, 64×64 change signatures |
| `Sources/NoseyFactChecker/AnthropicClient.swift` | Raw-HTTP client for the Messages API: structured-output checks, streamed chat, `capture_screen` tool, inbox check after every response |
| `Sources/NoseyFactChecker/LLMContact.swift` | Shared LLM inbox: reads the preamble and `contact_eli` tool, runs `llm_contact.py check` via `Process` |
| `Sources/NoseyFactChecker/ChatSession.swift` | One conversation and its API transcript; `ChatController` owns sessions and the saved draft |
| `Sources/NoseyFactChecker/ChatWindow.swift` | Floating chat window (SwiftUI): finding card, bubbles, input bar |
| `Sources/NoseyFactChecker/SettingsWindow.swift` | Settings window: API, watching, privacy, misfires, web search, hotkeys, prompts |
| `Sources/NoseyFactChecker/Settings.swift` | `AppSettings` (UserDefaults), default prompts and addenda, `APIKeyStore`, `Paths`, `Drafts` |
| `Sources/NoseyFactChecker/Models.swift` | `Finding` and the model's raw finding / response shapes |
| `Sources/NoseyFactChecker/CaptureStore.swift` | Saves captures and `findings.json`, prunes by retention |
| `Sources/NoseyFactChecker/MisfireStore.swift` | `misfires.json`: withdrawn flags that must never be flagged again; `ClaimText` similarity used for misfire and duplicate matching |
| `Sources/NoseyFactChecker/Notifier.swift` | UNUserNotificationCenter: post, open, dismiss top / all |
| `Sources/NoseyFactChecker/HotKey.swift` | Carbon global hotkeys, parsed from text like `ctrl+cmd+j`, resolved through the active layout |
| `Sources/NoseyFactChecker/UsageTracker.swift` | Per-day, per-model token usage and cost estimate (UserDefaults) |
| `Resources/Info.plist` | Bundle metadata: `com.elityre.nosey`, `LSUIElement` keeps it out of the Dock, usage descriptions |
| `Package.swift` | SwiftPM manifest (macOS 14+, links ScreenCaptureKit, UserNotifications, Carbon, ServiceManagement) |
| `build.sh` | Builds, bundles, signs `build/Nosey.app`; `--install` copies to `~/Applications`, `--run` relaunches |
| `.gitignore` | `.build/`, `build/`, Xcode state, logs |

## Runtime locations

- Installed app: `~/Applications/Nosey.app` (the copy Launch at Login points at); `build/Nosey.app` is the fresh build.
- Data: `~/Library/Application Support/Nosey/` – `captures/` (screenshots, pruned after the retention period), `findings.json`, `misfires.json`, `api-key` (0600).
- Settings, usage counters and unsent drafts: UserDefaults, domain `com.elityre.nosey` (`defaults read com.elityre.nosey`).
- Log: `~/Library/Logs/nosey.log`, one timestamped line per check, hotkey press, inbox event or failure; rotated to `nosey.old.log` at 2 MB. Builds before 2026-11-07 wrote `~/Library/Application Support/Nosey/nosey.log`. Also os_log, subsystem `com.elityre.nosey` (Console.app).
- Shared LLM inbox: `~/Documents/agent-coding/shared/` (preamble, tool, `llm_contact.py`, its `.venv`); messages land in `~/Library/Application Support/LLMInbox/messages.jsonl`, log in `~/Library/Logs/llm-inbox.log`.

## Common tasks

Requires Xcode 26 (or its command line tools) on macOS 14 or later.

```bash
cd ~/Documents/agent-coding/nosey-fact-checker
./build.sh                    # build and sign build/Nosey.app only
./build.sh --run              # build, then update and relaunch the installed copy (or launch build/ if none)
./build.sh --install --run    # also copy to ~/Applications (needed for Launch at Login)
swift build -c release        # compile check only, no bundle

# Quit (the menu's Quit Nosey does the same)
osascript -e 'tell application "Nosey" to quit'

# Logs
tail -f ~/Library/Logs/nosey.log
log stream --predicate 'subsystem == "com.elityre.nosey"' --level info

# Test without waiting for a real flag
#   Menu › Send a Test Notification      a fake finding through the notification path (click it to open the chat)
#   Menu › Check Screen Now              one full capture → API → notify cycle right now
#   Settings › Anthropic API › Test      pings the check model with the key (and the shared preamble + tool)
llm-inbox test                           # fake contact through the shared inbox (file, ntfy, email, Mac alert)
llm-inbox list                           # messages the model has sent, from Nosey or any other app
```

The script signs with your Apple Development certificate if one is in the keychain, so the
Screen Recording grant survives rebuilds. Without one it falls back to ad-hoc signing, and
macOS will ask for Screen Recording again after each rebuild.

## Settings that matter

1. **Screen Recording**: macOS prompts once. Grant it in System Settings › Privacy & Security
   › Screen Recording, then quit and relaunch Nosey (macOS requires a relaunch). Settings ›
   System shows whether it is granted.
2. **Notifications**: allow when asked. If you missed the prompt, Settings › Notification
   settings… opens the right pane. Set Nosey's alert style to **Alerts** there if you want
   flags to stay on screen until dismissed; banners disappear after a few seconds.
3. **API key**: Settings opens automatically when no key is stored. Paste your Anthropic API key
   and click Save (or Test). The key is written to
   `~/Library/Application Support/Nosey/api-key` with permissions 0600. `ANTHROPIC_API_KEY` in
   the environment is used as a fallback when launched from a shell.
   If the key is identity-linked (the API replies that `anthropic-workspace-id` is required),
   also paste the workspace ID (`wrkspc_…`, from Console › Settings › Workspaces) into the
   Workspace ID field.
4. **Launch at login**: Settings › System. Only register it from the copy in `~/Applications`
   (`./build.sh --install --run`); Settings warns if the login item points elsewhere.
5. **LLM inbox**: `~/Library/Application Support/LLMInbox/config.env` (ntfy topic, email) is set
   up once by `~/Documents/agent-coding/shared/install.sh`. Nosey runs the check with
   `shared/.venv/bin/python3` if present, else Homebrew's `python3`; the system `/usr/bin/python3`
   (3.9) is too old for `llm_contact.py`.

## Gotchas learned

- Two copies of Nosey (`build/` and `~/Applications`) can run at once, since macOS tells apps
  apart by path, and both bill every screen change. The app now quits if another instance is
  running, and `--run` always prefers the installed copy. Launch at Login remembers whichever
  path registered it, so it is re-registered from the installed copy on each launch.
- Without an Apple Development signature carrying a team ID, every rebuild looks like a new app
  to macOS and Screen Recording has to be granted again. `build.sh` refuses to continue if the
  signature lacks a `TeamIdentifier`.
- codesign fails with "resource fork, Finder information, or similar detritus not allowed" when
  the project sits in iCloud Drive: the file provider re-adds attributes at any moment. The
  bundle is assembled in a temp dir, `xattr -cr`'d, signed, then copied in.
- Screen Recording permission takes effect only after relaunching the app.
- Identity-linked API keys need the `anthropic-workspace-id` header; the error message says so,
  and Settings has a field for it.
- ScreenCaptureKit calls can hang across sleep. Every capture and request runs under a timeout,
  a watchdog abandons a cycle stuck for minutes, and wake notifications reset the state.
- os_log entries proved hard to retrieve after the fact, hence the plain-text `nosey.log`.
- Accessory apps (`LSUIElement`) get no menu bar, so ⌘X/⌘C/⌘V/⌘A/⌘Z do nothing in text fields
  unless a hidden Edit menu is installed (`setupMainMenu`).
- `@Published` emits on `willSet`, so a sink that redraws the menu bar icon must hop to the next
  main-queue turn or it draws the old state.
- The global hotkey and the in-window fallback shortcut can fire for the same keypress and cancel
  each other out; the toggle is debounced by 300 ms. Hotkeys bind to physical key positions, so
  they are re-resolved when the keyboard layout changes.
- Web search results come back encrypted and must be sent back block-for-block on later turns;
  the API rejects a conversation where they were altered. A reply cut short by Stop goes back
  as plain text instead. The API can also pause a turn (`pause_turn`) after a search; sending
  the same content back resumes it, capped at 8 continuations.
- The newer web search tool version routes searches through code execution, hiding the queries
  and often returning no citations, without saving tokens. The basic `web_search_20250305` is used.
- A client tool call with no arguments (`capture_screen`) can arrive with no `input_json_delta`
  fragments at all; the block still needs an `input` dict or the API rejects it on the next turn.
- The model occasionally returns a blank placeholder finding instead of an empty list; blank
  claims are dropped.
- Adaptive thinking + effort are only valid on the 4.6+ generation; older models reject them,
  so `supportsAdaptive` gates by model name.
- Anything that varies per check (timestamps, display counts) must stay out of the cached system
  blocks or the cache misses every time; it goes in the user message.
- `pkill -x Nosey` can silently fail; `build.sh --run` waits on `pgrep` and escalates to `-9`
  before `open`ing the new build. Restart means quit then launch, never a bare `pkill`.
- The shared `llm_contact.py` uses `dict | None` annotations, which the system Python 3.9 cannot
  parse. Nosey picks `shared/.venv/bin/python3` or Homebrew's `python3` first; a GUI app's PATH is
  minimal, so `env python3` would have found the wrong one.
