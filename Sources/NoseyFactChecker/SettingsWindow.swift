import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(engine: FactCheckEngine) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Nosey Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(engine: engine))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    let engine: FactCheckEngine

    var body: some View {
        TabView {
            GeneralSettings(engine: engine).tabItem { Text("General") }
            PromptSettings().tabItem { Text("Prompts") }
        }
        .padding(12)
        .frame(minWidth: 600, minHeight: 560)
    }
}

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    let engine: FactCheckEngine
    @State private var apiKey = APIKeyStore.read() ?? ""
    @State private var keyStatus = ""
    @State private var hotKeyDraft = AppSettings.shared.hotKey
    @State private var dismissDraft = AppSettings.shared.dismissHotKey
    @State private var loginError = ""

    var body: some View {
        Form {
            Section("Anthropic API") {
                HStack {
                    SecureField("sk-ant-…", text: $apiKey)
                        .onSubmit { saveKey() }
                    Button("Save") { saveKey() }
                    Button("Test") { testKey() }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption).foregroundStyle(.secondary) }
                TextField("Workspace ID (only for identity-linked keys, wrkspc_…)", text: $settings.workspaceID)
                    .onSubmit { if case .error = engine.state { engine.checkNow() } }
                Text("Newer keys are tied to your identity and require the workspace they act in. Find the ID in the Anthropic Console under Settings › Workspaces.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Model", text: $settings.model)
                Picker("Effort", selection: $settings.effort) {
                    Text("Low (fastest, cheapest)").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                Text("Effort applies to the background checks. Chat replies use at least medium.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Watching") {
                HStack {
                    Slider(value: $settings.intervalSeconds, in: 2...60, step: 1)
                    Text("every \(Int(settings.intervalSeconds)) s").frame(width: 80, alignment: .trailing)
                }
                HStack {
                    Slider(value: $settings.changeThreshold, in: 0.002...0.2)
                    Text(String(format: "%.1f%% change", settings.changeThreshold * 100)).frame(width: 100, alignment: .trailing)
                }
                Text("A screenshot is sent only when at least this much of the screen changed since the last one. Lower is more sensitive (and more expensive).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $settings.minConfidence, in: 0.3...1)
                    Text("≥ \(Int(settings.minConfidence * 100))% confidence").frame(width: 130, alignment: .trailing)
                }
                HStack {
                    Slider(value: $settings.retentionHours, in: 1...72, step: 1)
                    Text("keep \(Int(settings.retentionHours)) h").frame(width: 80, alignment: .trailing)
                }
                Toggle("Start watching when Nosey launches", isOn: $settings.startWatchingOnLaunch)
                Toggle("Play a sound with notifications", isOn: $settings.notifySound)
                Text("To keep notifications on screen until you dismiss them, set Nosey's alert style to “Alerts” in System Settings › Notifications › Nosey. Banners disappear on their own after a few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Chat window") {
                HStack {
                    TextField("Chat hotkey, e.g. ctrl+cmd+j", text: $hotKeyDraft)
                        .onSubmit { settings.hotKey = hotKeyDraft }
                    Button("Apply") { settings.hotKey = hotKeyDraft }
                }
                HStack {
                    TextField("Dismiss-top-notification hotkey, e.g. ctrl+cmd+k", text: $dismissDraft)
                        .onSubmit { settings.dismissHotKey = dismissDraft }
                    Button("Apply") { settings.dismissHotKey = dismissDraft }
                }
                if !settings.hotKeyStatus.isEmpty {
                    Text(settings.hotKeyStatus).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Default size", selection: $settings.chatWindowSize) {
                    ForEach(ChatWindowSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, on in updateLoginItem(on) }
                if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Screen Recording permission…") {
                        ScreenCapturer.requestPermission()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    Button("Notification settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    Button("Show captures folder") { NSWorkspace.shared.open(Paths.captures) }
                }
                Text(ScreenCapturer.hasPermission ? "Screen Recording: granted" : "Screen Recording: NOT granted (required)")
                    .font(.caption).foregroundStyle(ScreenCapturer.hasPermission ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
    }

    private func saveKey() {
        APIKeyStore.write(apiKey)
        keyStatus = apiKey.isEmpty ? "Key removed." : "Key saved."
        if case .error = engine.state { engine.checkNow() }
    }

    private func testKey() {
        APIKeyStore.write(apiKey)
        keyStatus = "Testing…"
        Task {
            do {
                let reply = try await engine.client.ping(model: settings.model)
                keyStatus = "Works. Model replied: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                keyStatus = error.localizedDescription
            }
        }
    }

    private func updateLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = "Launch at login failed: \(error.localizedDescription). Try installing Nosey.app into ~/Applications (./build.sh --install)."
            settings.launchAtLogin = !on
        }
    }
}

struct PromptSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Fact-check prompt").font(.headline)
                Spacer()
                Button("Reset to default") { settings.factCheckPrompt = AppSettings.defaultFactCheckPrompt }
            }
            Text("This is the system prompt for every background check. Tune it to say what is and isn't worth flagging. Changes apply to the next check.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $settings.factCheckPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)

            HStack {
                Text("Chat prompt").font(.headline)
                Spacer()
                Button("Reset to default") { settings.chatPrompt = AppSettings.defaultChatPrompt }
            }
            TextEditor(text: $settings.chatPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
        }
        .padding(8)
    }
}
