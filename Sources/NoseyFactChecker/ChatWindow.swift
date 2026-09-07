import AppKit
import SwiftUI

/// Floating chat window, toggled by the global hotkey. Same hotkey (or Esc / the close button) hides it.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let controller: ChatController
    private let settings = AppSettings.shared

    init(controller: ChatController) {
        self.controller = controller
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Nosey"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 380, height: 300)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ChatView(controller: controller, windowController: self))
    }

    var isShowing: Bool { window.isVisible }
    private var lastToggle = Date.distantPast

    /// Asked which session to open when the hotkey shows the window (e.g. the top notification on screen).
    /// Called with a completion; pass nil to fall back to the default session.
    var sessionForHotKey: ((@escaping (ChatSession?) -> Void) -> Void)?

    /// Visible → hide, otherwise show. Debounced so the global hotkey and the in-window fallback
    /// shortcut firing for the same keypress do not cancel each other out.
    func toggle() {
        guard Date().timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = Date()
        if window.isVisible {
            hide()
        } else if let sessionForHotKey {
            sessionForHotKey { [weak self] session in self?.show(session: session) }
        } else {
            show()
        }
    }

    func show(session: ChatSession? = nil) {
        let s = session ?? controller.defaultSession()
        controller.current = s
        if let f = s.finding { controller.engine?.markRead(f.id) }
        applySize(settings.chatWindowSize)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        controller.focusToken += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if !self.window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
                self.controller.focusToken += 1
            }
            FileLog.write("chat shown; active=\(NSApp.isActive) key=\(self.window.isKeyWindow)")
        }
    }

    func hide() {
        FileLog.write("chat hidden")
        window.orderOut(nil)
        NSApp.hide(nil)   // hand focus back to whatever the user was using
    }

    func applySize(_ size: ChatWindowSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let pad: CGFloat = 8
        let frame: NSRect
        switch size {
        case .quarter:
            let w = max(420, v.width / 2 - pad), h = max(320, v.height / 2 - pad)
            frame = NSRect(x: v.maxX - w - pad, y: v.maxY - h - pad, width: w, height: h)
        case .half:
            frame = NSRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .full:
            frame = v
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

// MARK: - SwiftUI

struct ChatView: View {
    @ObservedObject var controller: ChatController
    let windowController: ChatWindowController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let session = controller.current {
                SessionView(session: session, controller: controller, windowController: windowController)
                    .id(session.id)
            } else {
                Spacer()
                Text("No conversation yet.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 62) // room for traffic lights
            Menu {
                Button("New free chat") { controller.current = controller.newFreeSession(); controller.focusToken += 1 }
                if let engine = controller.engine, !engine.findings.isEmpty {
                    Divider()
                    ForEach(engine.findings.prefix(20)) { f in
                        Button {
                            controller.current = controller.session(for: f)
                            engine.markRead(f.id)
                            controller.focusToken += 1
                        } label: {
                            Text("\(f.date.formatted(date: .omitted, time: .shortened))  \(f.summary)")
                        }
                    }
                }
            } label: {
                Label(controller.current?.title ?? "Conversations", systemImage: "bubble.left.and.text.bubble.right")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 360, alignment: .leading)

            Spacer()

            Picker("", selection: $settings.chatWindowSize) {
                ForEach(ChatWindowSize.allCases) { s in Text(s.label).tag(s) }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .onChange(of: settings.chatWindowSize) { _, new in windowController.applySize(new) }
            .help("Window size (⌘1 quarter, ⌘2 half, ⌘3 full)")

            // Hidden buttons providing the keyboard shortcuts.
            Group {
                Button("") { settings.chatWindowSize = .quarter }.keyboardShortcut("1", modifiers: .command)
                Button("") { settings.chatWindowSize = .half }.keyboardShortcut("2", modifiers: .command)
                Button("") { settings.chatWindowSize = .full }.keyboardShortcut("3", modifiers: .command)
                Button("") { windowController.hide() }.keyboardShortcut("w", modifiers: .command)
                if let sc = HotKeyManager.swiftUIShortcut(settings.hotKey) {
                    Button("") { windowController.toggle() }.keyboardShortcut(sc)
                }
            }
            .frame(width: 0, height: 0).opacity(0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct SessionView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var controller: ChatController
    let windowController: ChatWindowController
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let f = session.finding { FindingCard(finding: f) }
                        ForEach(session.visibleMessages) { m in
                            MessageBubble(message: m)
                        }
                        if let err = session.error {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: session.messages) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            inputBar
        }
        .onAppear { focusInput() }
        .onChange(of: controller.focusToken) { _, _ in focusInput() }
    }

    private func focusInput() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { inputFocused = true }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !session.pendingImages.isEmpty {
                HStack {
                    Label("\(session.pendingImages.count) screenshot(s) attached to your next message", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { session.pendingImages = [] }.buttonStyle(.link).font(.caption)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    controller.attachCurrentScreen(to: session)
                } label: { Image(systemName: "camera.viewfinder") }
                .help("Attach a fresh screenshot of all displays to your next message")

                TextField("Ask a question or push back… (Enter to send, Esc to close)", text: $controller.draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { send() }
                    .onExitCommand { windowController.hide() }
                    .disabled(session.isStreaming)

                if session.isStreaming {
                    Button { session.stop() } label: { Image(systemName: "stop.circle.fill") }
                        .help("Stop generating")
                } else {
                    Button { send() } label: { Image(systemName: "arrow.up.circle.fill") }
                        .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send")
                }
            }
        }
        .padding(10)
    }

    private func send() {
        let text = controller.draft
        controller.draft = ""
        session.send(text)
    }
}

struct FindingCard: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Flagged \(finding.date.formatted(date: .abbreviated, time: .shortened)) · display \(finding.display) · \(Int(finding.confidence * 100))% confident",
                      systemImage: "flag.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = finding.captureURLs.first, FileManager.default.fileExists(atPath: url.path) {
                    Button("Open screenshot") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Text("“\(finding.claim)”")
                .italic()
                .textSelection(.enabled)
            Text(finding.summary).bold().textSelection(.enabled)
            Text(finding.explanation).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                if !message.images.isEmpty {
                    Label("\(message.images.count) screenshot(s)", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if message.text.isEmpty && message.streaming {
                    ProgressView().controlSize(.small)
                } else {
                    Text(MessageBubble.render(message.text))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
