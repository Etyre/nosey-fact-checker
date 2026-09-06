import AppKit
import Carbon
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = AppSettings.shared
    private var engine: FactCheckEngine!
    private var chat: ChatController!
    private var chatWindow: ChatWindowController!
    private var settingsWindow: SettingsWindowController!
    private let hotKey = HotKeyManager()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = FactCheckEngine()
        chat = ChatController(client: engine.client)
        chat.engine = engine
        chatWindow = ChatWindowController(controller: chat)
        settingsWindow = SettingsWindowController(engine: engine)

        setupMainMenu()
        setupStatusItem()
        Notifier.shared.setup()
        Notifier.shared.onOpen = { [weak self] id in
            guard let self, let f = self.engine.finding(id: id) else { return }
            self.chatWindow.show(session: self.chat.session(for: f))
        }
        engine.onNewFindings = { [weak self] _ in self?.refreshIcon() }
        // @Published emits on willSet, so redraw on the next main-queue turn, after the value has changed.
        engine.$findings.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshIcon() }.store(in: &cancellables)
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshIcon() }.store(in: &cancellables)

        // Diagnostic: log raw key presses that reach Nosey's own windows (no permission needed for local events).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let f = e.modifierFlags
            guard f.contains(.command) || f.contains(.control) else { return e }
            var mods: [String] = []
            if f.contains(.control) { mods.append("ctrl") }
            if f.contains(.option) { mods.append("alt") }
            if f.contains(.command) { mods.append("cmd") }
            if f.contains(.shift) { mods.append("shift") }
            if f.contains(.function) { mods.append("fn") }
            if f.contains(.capsLock) { mods.append("caps") }
            FileLog.write("keyDown in Nosey window: code=\(e.keyCode) mods=\(mods.joined(separator: "+")) chars=\(e.charactersIgnoringModifiers ?? "")")
            return e
        }
        registerHotKeys()
        // Hotkeys bind to physical key positions, so re-resolve them when the keyboard layout changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.registerHotKeys() }
        settings.$hotKey.dropFirst().removeDuplicates().merge(with: settings.$dismissHotKey.dropFirst().removeDuplicates())
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)

        // Do not call CGRequestScreenCaptureAccess here: ScreenCaptureKit shows the system prompt
        // itself the first time a capture is attempted without permission, and calling it on every
        // launch produced repeated dialogs. The Settings button still offers an explicit request.
        if APIKeyStore.read() == nil {
            settingsWindow.show()
        }
        if settings.startWatchingOnLaunch {
            engine.start()
        }
    }

    /// Chat hotkey toggles the chat window; dismiss hotkey clears Nosey's notifications from the screen.
    private func registerHotKeys() {
        var status: [String] = []
        if let err = hotKey.register(settings.hotKey, id: 1, action: { [weak self] in
            FileLog.write("hotkey: chat toggle pressed")
            self?.chatWindow.toggle()
        }) {
            status.append("Chat hotkey: \(err)")
        } else {
            status.append("\(HotKeyManager.describe(settings.hotKey)) opens/closes the chat")
        }
        if let err = hotKey.register(settings.dismissHotKey, id: 2, action: {
            FileLog.write("hotkey: dismiss pressed")
            Notifier.shared.dismissAll()
        }) {
            status.append("Dismiss hotkey: \(err)")
        } else {
            status.append("\(HotKeyManager.describe(settings.dismissHotKey)) dismisses notifications")
        }
        status.append("layout: \(HotKeyManager.currentLayoutName)")
        settings.hotKeyStatus = status.joined(separator: " · ")
        FileLog.write("hotkeys: " + settings.hotKeyStatus)
    }

    /// Accessory apps get no menu bar, so without this ⌘X/⌘C/⌘V/⌘A/⌘Z do nothing in text fields.
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Nosey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let unread = engine.unreadCount > 0
        let paused: Bool
        let desc: String
        if unread {
            paused = !engine.isWatching; desc = "Nosey: unread flags"
        } else if case .error = engine.state {
            paused = true; desc = "Nosey: problem, open the menu"
        } else if engine.isWatching {
            paused = false; desc = "Nosey: watching"
        } else {
            paused = true; desc = "Nosey: paused"
        }
        button.image = AppDelegate.noseIcon(paused: paused, badge: unread)
        button.toolTip = desc
    }

    /// Nose glyph, filled while watching, outlined with a slash while paused, with a dot badge for unread flags.
    private static func noseIcon(paused: Bool, badge: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let symbol = NSImage(systemSymbolName: paused ? "nose" : "nose.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        let img = NSImage(size: size, flipped: false) { rect in
            let glyphRect = NSRect(x: 1, y: 1, width: 16, height: 16)
            symbol?.draw(in: glyphRect)
            NSColor.black.setStroke()
            NSColor.black.setFill()
            if paused {
                let line = NSBezierPath()
                line.lineWidth = 1.6
                line.lineCapStyle = .round
                line.move(to: NSPoint(x: 3, y: 2))
                line.line(to: NSPoint(x: 15, y: 16))
                line.stroke()
            }
            if badge {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6.5, y: rect.maxY - 6.5, width: 6, height: 6)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshIcon()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let status: String
        switch engine.state {
        case .watching:
            if let last = engine.lastCheck {
                status = "Watching · last check \(Int(Date().timeIntervalSince(last)))s ago · \(engine.lastNote)"
            } else {
                status = "Watching · \(engine.lastNote)"
            }
        case .paused(let until):
            if let until { status = "Paused until \(until.formatted(date: .omitted, time: .shortened))" } else { status = "Paused" }
        case .error(let msg):
            status = "Problem (will retry): \(msg)"
        }
        let statusItemMenu = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)
        menu.addItem(.separator())

        let openChat = NSMenuItem(title: "Open Chat  (\(HotKeyManager.describe(settings.hotKey)))", action: #selector(openChat(_:)), keyEquivalent: "")
        openChat.target = self
        menu.addItem(openChat)

        let check = NSMenuItem(title: "Check Screen Now", action: #selector(checkNow(_:)), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let dismiss = NSMenuItem(title: "Dismiss Notifications  (\(HotKeyManager.describe(settings.dismissHotKey)))", action: #selector(dismissNotifications(_:)), keyEquivalent: "")
        dismiss.target = self
        menu.addItem(dismiss)
        let preview = NSMenuItem(title: "Send a Test Notification", action: #selector(testNotification(_:)), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)

        if engine.isWatching {
            let p = NSMenuItem(title: "Pause", action: #selector(pause(_:)), keyEquivalent: "")
            p.target = self; menu.addItem(p)
            let p1 = NSMenuItem(title: "Pause for 1 Hour", action: #selector(pauseHour(_:)), keyEquivalent: "")
            p1.target = self; menu.addItem(p1)
        } else {
            let r = NSMenuItem(title: "Resume Watching", action: #selector(resume(_:)), keyEquivalent: "")
            r.target = self; menu.addItem(r)
        }
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "Recent Flags", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if engine.findings.isEmpty {
            let none = NSMenuItem(title: "Nothing flagged yet", action: nil, keyEquivalent: ""); none.isEnabled = false
            sub.addItem(none)
        } else {
            for f in engine.findings.prefix(15) {
                let title = "\(f.read ? "" : "● ")\(f.date.formatted(date: .omitted, time: .shortened))  \(String(f.summary.prefix(70)))"
                let item = NSMenuItem(title: title, action: #selector(openFinding(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = f.id
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let mark = NSMenuItem(title: "Mark All Read", action: #selector(markAllRead(_:)), keyEquivalent: "")
            mark.target = self; sub.addItem(mark)
        }
        recent.submenu = sub
        menu.addItem(recent)

        let usage = NSMenuItem(title: UsageTracker.shared.summary(model: settings.model) + " (estimate)", action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)
        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let folder = NSMenuItem(title: "Show Captures Folder", action: #selector(showFolder(_:)), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let logItem = NSMenuItem(title: "Open Log File", action: #selector(openLog(_:)), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nosey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func openChat(_ sender: Any?) { chatWindow.show() }
    @objc private func checkNow(_ sender: Any?) { engine.checkNow() }
    @objc private func pause(_ sender: Any?) { engine.pause() }
    @objc private func pauseHour(_ sender: Any?) { engine.pause(for: 3600) }
    @objc private func resume(_ sender: Any?) { engine.start() }
    @objc private func openSettings(_ sender: Any?) { settingsWindow.show() }
    @objc private func showFolder(_ sender: Any?) { NSWorkspace.shared.open(Paths.captures) }
    @objc private func openLog(_ sender: Any?) { NSWorkspace.shared.open(FileLog.url) }
    @objc private func markAllRead(_ sender: Any?) { engine.markAllRead() }
    @objc private func dismissNotifications(_ sender: Any?) { Notifier.shared.dismissAll() }
    @objc private func testNotification(_ sender: Any?) {
        let sample = Finding(id: UUID(), date: Date(),
                             claim: "The Great Wall of China is visible from the Moon with the naked eye.",
                             summary: "Test: not visible from the Moon; it is far too narrow.",
                             explanation: "This is a test notification. The Great Wall is only a few meters wide, far below what the eye can resolve from lunar distance.",
                             confidence: 0.98, display: 1, captureFiles: [], read: true)
        Notifier.shared.post(sample, hotKeyLabel: HotKeyManager.describe(settings.hotKey))
    }
    @objc private func openFinding(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let f = engine.finding(id: id) else { return }
        chatWindow.show(session: chat.session(for: f))
    }
}
