import Testing
import Foundation
import Carbon
@testable import RecLib

@Suite("Service")
struct ServiceTests {
    @Test func plistIsValidAndKeepsAlive() throws {
        let text = Service.plist(executable: "/Users/me/Applications/Rec.app/Contents/MacOS/Rec", logDir: "/Users/me/Library/Logs/Rec")
        let data = text.data(using: .utf8)!
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let dict = try #require(obj)
        #expect(dict["Label"] as? String == "com.rec.app")
        #expect(dict["RunAtLoad"] as? Bool == true)
        #expect(dict["KeepAlive"] as? Bool == true)
        #expect((dict["ProgramArguments"] as? [String])?.first == "/Users/me/Applications/Rec.app/Contents/MacOS/Rec")
        #expect((dict["StandardErrorPath"] as? String)?.hasSuffix("rec.err.log") == true)
    }

    @Test func plistPathUnderLaunchAgents() {
        #expect(Service.plistURL.path.hasSuffix("Library/LaunchAgents/com.rec.app.plist"))
    }
}

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func displayStrings() {
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | cmdKey)).display == "⌃⌘R")
        #expect(Shortcut(keyCode: UInt32(kVK_F9), modifiers: 0).display == "F9")
        #expect(Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(optionKey | cmdKey)).display == "⌥⌘E")
    }

    @Test func presetsDoNotCollide() {
        let toggles = ShortcutPreset.toggle.map(\.shortcut)
        let picks = ShortcutPreset.pick.map(\.shortcut)
        for t in toggles { #expect(!picks.contains(t)) }
        #expect(Set(ShortcutPreset.toggle.map(\.label)).count == ShortcutPreset.toggle.count)
        #expect(Set(ShortcutPreset.pick.map(\.label)).count == ShortcutPreset.pick.count)
    }

    @Test func presetLabelsMatchAcrossLists() {
        #expect(ShortcutPreset.toggle.map(\.label) == ShortcutPreset.pick.map(\.label))
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func defaultsAreSane() {
        let d = UserDefaults(suiteName: "rec.tests.\(UUID().uuidString)")!
        let s = Settings(defaults: d)
        #expect(s.micEnabled)
        #expect(s.systemAudioEnabled)
        #expect(s.quality == .high)
        #expect(s.copyAfterStop)
        #expect(s.revealAfterStop)
        #expect(s.mixdownAfterStop)
        #expect(!s.keepRawFile)
        #expect(s.outputDirectory.path.hasSuffix("Movies/Recordings"))
    }

    @Test func settingsPersist() {
        let d = UserDefaults(suiteName: "rec.tests.\(UUID().uuidString)")!
        var s = Settings(defaults: d)
        s.micEnabled = false
        s.quality = .medium
        let again = Settings(defaults: d)
        #expect(!again.micEnabled)
        #expect(again.quality == .medium)
    }
}
