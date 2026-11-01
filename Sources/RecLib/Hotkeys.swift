import Carbon
import Cocoa

public struct Shortcut: Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    private var keyName: String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_E: "E", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Z: "Z",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
            kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return letters[Int(keyCode)] ?? "Key\(keyCode)"
    }
}

public struct ShortcutPreset {
    public let label: String
    public let shortcut: Shortcut

    public static let toggle: [ShortcutPreset] = [
        .init(label: "Default", shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | cmdKey))),
        .init(label: "Single key", shortcut: Shortcut(keyCode: UInt32(kVK_F9), modifiers: 0)),
        .init(label: "Option", shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey))),
        .init(label: "Shift", shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | shiftKey))),
    ]

    public static let pick: [ShortcutPreset] = [
        .init(label: "Default", shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey | cmdKey))),
        .init(label: "Single key", shortcut: Shortcut(keyCode: UInt32(kVK_F10), modifiers: 0)),
        .init(label: "Option", shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(optionKey | cmdKey))),
        .init(label: "Shift", shortcut: Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey | shiftKey))),
    ]
}

// Carbon because there is still no public modern API for global hotkeys.
public final class Hotkeys {
    public enum Action { case toggle, pick }

    private static let toggleID: UInt32 = 1
    private static let pickID: UInt32 = 2
    private static let signature = OSType(0x52454331) // REC1

    public private(set) var toggle: Shortcut
    public private(set) var pick: Shortcut
    public private(set) var registrationError: String?

    private var refs: [EventHotKeyRef?] = [nil, nil]
    private var handlerRef: EventHandlerRef?
    private var handler: ((Action) -> Void)?
    private let defaults = UserDefaults.standard

    public init() {
        toggle = ShortcutPreset.toggle.first { $0.label == UserDefaults.standard.string(forKey: "hotkey.toggle") }?.shortcut
            ?? ShortcutPreset.toggle[0].shortcut
        pick = ShortcutPreset.pick.first { $0.label == UserDefaults.standard.string(forKey: "hotkey.pick") }?.shortcut
            ?? ShortcutPreset.pick[0].shortcut
    }

    public var togglePresetLabel: String { defaults.string(forKey: "hotkey.toggle") ?? "Default" }
    public var pickPresetLabel: String { defaults.string(forKey: "hotkey.pick") ?? "Default" }

    public func register(_ handler: @escaping (Action) -> Void) {
        self.handler = handler
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let hk = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async {
                    switch id.id {
                    case Hotkeys.toggleID: hk.handler?(.toggle)
                    case Hotkeys.pickID: hk.handler?(.pick)
                    default: break
                    }
                }
                return noErr
            }, 1, &spec, me, &handlerRef)
        }
        registerAll()
    }

    @discardableResult
    public func setToggle(_ preset: ShortcutPreset) -> String? {
        unregisterAll()
        toggle = preset.shortcut
        defaults.set(preset.label, forKey: "hotkey.toggle")
        registerAll()
        return registrationError
    }

    @discardableResult
    public func setPick(_ preset: ShortcutPreset) -> String? {
        unregisterAll()
        pick = preset.shortcut
        defaults.set(preset.label, forKey: "hotkey.pick")
        registerAll()
        return registrationError
    }

    public func unregister() {
        unregisterAll()
        if let r = handlerRef { RemoveEventHandler(r); handlerRef = nil }
        handler = nil
    }

    private func registerAll() {
        var errors: [String] = []
        for (i, (sc, id)) in [(toggle, Hotkeys.toggleID), (pick, Hotkeys.pickID)].enumerated() {
            let hkID = EventHotKeyID(signature: Hotkeys.signature, id: id)
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, hkID, GetApplicationEventTarget(), 0, &refs[i])
            if status != noErr {
                errors.append("\(sc.display) is taken by another app")
                NSLog("Rec: hotkey %@ failed (%d)", sc.display, status)
            }
        }
        registrationError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func unregisterAll() {
        for i in refs.indices {
            if let r = refs[i] { UnregisterEventHotKey(r); refs[i] = nil }
        }
    }
}
