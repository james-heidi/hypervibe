import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ButtonMappingStoreTests {
    static func main() {
        testFreshInstallDefaults()
        testSchema9ResetsIntendedKeys()
        testMenuButtonsCoverDefaults()
        testSanitizeClearsVoiceHotkeys()
        print("ButtonMappingStoreTests: PASS")
    }

    private static func testFreshInstallDefaults() {
        let result = ButtonMappingStore.migrate(saved: nil, savedSchema: 0)
        expect(result.mappings["playPause"] == .escKey, "playPause default")
        expect(result.mappings["menu"] == .commandBackspace, "menu default")
        expect(result.mappings["select"] == .enterKey, "select default")
        expect(result.mappings["volumeUp"] == .volumeUp, "volumeUp default")
        expect(result.mappings["volumeDown"] == .volumeDown, "volumeDown default")
        expect(result.mappings["mute"] == .mute, "mute default")
        expect(result.mappings["tv"] == .ctrlC, "tv default")
        expect(result.schema == 9, "schema 9")
    }

    private static func testSchema9ResetsIntendedKeys() {
        let saved: [String: String] = [
            "playPause": ButtonAction.enterKey.rawValue,
            "menu": ButtonAction.backspace.rawValue,
            "select": ButtonAction.trackpadClick.rawValue,
            "tv": ButtonAction.ctrlC.rawValue,
            "ringUp": ButtonAction.upKey.rawValue,
        ]
        let result = ButtonMappingStore.migrate(saved: saved, savedSchema: 8)
        expect(result.mappings["playPause"] == .escKey, "schema9 resets playPause")
        expect(result.mappings["menu"] == .commandBackspace, "schema9 resets menu")
        expect(result.mappings["select"] == .enterKey, "schema9 resets select")
        expect(result.mappings["tv"] == .ctrlC, "tv preserved")
        expect(result.mappings["ringUp"] == .upKey, "ringUp preserved")
    }

    private static func testMenuButtonsCoverDefaults() {
        let keys = Set(ButtonMappingStore.menuButtons.map(\.key))
        for key in ButtonMappingStore.defaults.keys {
            expect(keys.contains(key), "menu list missing default key \(key)")
        }
    }

    private static func testSanitizeClearsVoiceHotkeys() {
        var mappings: [String: ButtonAction] = [
            "playPause": .spaceKey,
            "menu": .commandBackspace,
        ]
        let notes = ButtonMappingStore.sanitize(&mappings)
        expect(mappings["playPause"] == ButtonAction.none, "voice hotkey cleared")
        expect(!notes.isEmpty, "sanitize notes")
    }
}
