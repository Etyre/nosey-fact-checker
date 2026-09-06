import Carbon
import Foundation
import SwiftUI

/// System-wide hotkeys via Carbon's RegisterEventHotKey (no Accessibility permission needed).
/// Several hotkeys can be registered, each identified by a small integer id.
final class HotKeyManager {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // The dispatcher target receives hotkey events whether or not this app is frontmost;
        // the application target misses them while our own window is key.
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hkID.id
            DispatchQueue.main.async { mgr.handlers[id]?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    deinit {
        for id in Array(refs.keys) { unregister(id: id) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        handlers[id] = nil
    }

    /// Registers a combo like "ctrl+alt+cmd+f" under `id`. Returns nil on success or an error description.
    @discardableResult
    func register(_ combo: String, id: UInt32, action: @escaping () -> Void) -> String? {
        unregister(id: id)
        guard let (code, mods) = HotKeyManager.parse(combo) else {
            return "Could not parse “\(combo)”. Use e.g. ctrl+cmd+j or shift+cmd+space."
        }
        guard mods != 0 else { return "Add at least one modifier (ctrl, alt, cmd, shift)." }
        let hkID = EventHotKeyID(signature: OSType(0x4E534559), id: id) // 'NSEY'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, mods, hkID, GetEventDispatcherTarget(), 0, &ref)
        if status != noErr || ref == nil {
            return "System refused the hotkey (error \(status)); it may already be taken."
        }
        refs[id] = ref
        handlers[id] = action
        return nil
    }

    static func parse(_ combo: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in combo.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" }) {
            let part = String(raw).trimmingCharacters(in: .whitespaces)
            switch part {
            case "ctrl", "control", "^": mods |= UInt32(controlKey)
            case "alt", "opt", "option", "⌥": mods |= UInt32(optionKey)
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default:
                guard key == nil, let code = keyCodes[part] else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        return (key, mods)
    }

    /// SwiftUI equivalent of a combo, for an in-window fallback shortcut. Letters, digits and space only.
    static func swiftUIShortcut(_ combo: String) -> KeyboardShortcut? {
        var mods: SwiftUI.EventModifiers = []
        var key: KeyEquivalent?
        for raw in combo.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" }) {
            let p = String(raw)
            switch p {
            case "ctrl", "control", "^": mods.insert(.control)
            case "alt", "opt", "option", "⌥": mods.insert(.option)
            case "cmd", "command", "⌘": mods.insert(.command)
            case "shift", "⇧": mods.insert(.shift)
            case "space": key = .space
            default:
                guard p.count == 1, let c = p.first, c.isLetter || c.isNumber else { return nil }
                key = KeyEquivalent(c)
            }
        }
        guard let key, !mods.isEmpty else { return nil }
        return KeyboardShortcut(key, modifiers: mods)
    }

    static func describe(_ combo: String) -> String {
        guard parse(combo) != nil else { return combo }
        var out = ""
        var keyName = ""
        for raw in combo.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "-" }) {
            let p = String(raw)
            switch p {
            case "ctrl", "control": out += "⌃"
            case "alt", "opt", "option": out += "⌥"
            case "shift": out += "⇧"
            case "cmd", "command": out += "⌘"
            default: keyName = p == "space" ? "Space" : p.uppercased()
            }
        }
        return out + keyName
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
        "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
        "delete": UInt32(kVK_Delete), "backspace": UInt32(kVK_Delete),
        "`": UInt32(kVK_ANSI_Grave), "grave": UInt32(kVK_ANSI_Grave), "=": UInt32(kVK_ANSI_Equal),
        "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket), ";": UInt32(kVK_ANSI_Semicolon),
        "'": UInt32(kVK_ANSI_Quote), ",": UInt32(kVK_ANSI_Comma), ".": UInt32(kVK_ANSI_Period),
        "/": UInt32(kVK_ANSI_Slash), "\\": UInt32(kVK_ANSI_Backslash), "minus": UInt32(kVK_ANSI_Minus),
        "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow), "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
        "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3), "f4": UInt32(kVK_F4),
        "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6), "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8),
        "f9": UInt32(kVK_F9), "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),
    ]
}
