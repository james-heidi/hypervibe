//
//  ButtonMappingStore.swift
//  HyperVibe
//
//  Pure source of truth for Siri Remote button → action defaults and schema
//  migrations. MenuBarManager is glue around UserDefaults persistence.
//

import Foundation

enum ButtonMappingStore {
    /// Confirmed product defaults for fresh installs / schema-9 reset.
    ///
    /// `ButtonAction.recoverDictation` is intentionally absent: recovery is opt-in
    /// per user, and sanitize() must keep it assignable to any button (it is
    /// neither a hold action nor a legacy dictation hotkey).
    static let defaults: [String: ButtonAction] = [
        "playPause": .escKey,
        "menu": .commandBackspace,
        "select": .enterKey,
        "ringUp": .upKey,
        "ringDown": .downKey,
        "ringLeft": .leftKey,
        "ringRight": .rightKey,
        "volumeUp": .volumeUp,
        "volumeDown": .volumeDown,
        "mute": .mute,
        "tv": .ctrlC,
    ]

    /// Buttons shown in the 按键映射 submenu — kept here so tests can catch drift
    /// against `defaults` keys.
    static let menuButtons: [(key: String, label: String)] = [
        ("select", "触控板点击"),
        ("ringUp", "环上"),
        ("ringDown", "环下"),
        ("ringLeft", "环左"),
        ("ringRight", "环右"),
        ("menu", "返回键 ‹"),
        ("tv", "TV 键"),
        ("playPause", "播放/暂停"),
        ("volumeUp", "音量 +"),
        ("volumeDown", "音量 −"),
        ("mute", "静音键"),
    ]

    static let currentSchema = 9

    /// Keys whose intended default changed in v9 — reset only these so unrelated
    /// customizations survive the migration.
    static let schema9Resets: Set<String> = [
        "playPause", "menu", "select", "volumeUp", "volumeDown", "mute",
    ]

    struct MigrationResult {
        var mappings: [String: ButtonAction]
        var schema: Int
        var notes: [String]
    }

    static func migrate(saved: [String: String]?, savedSchema: Int) -> MigrationResult {
        var notes: [String] = []
        var raw = saved ?? [:]

        if savedSchema < 3 {
            raw.removeAll()
            notes.append("schema<\(savedSchema): wiped pre-v3 mappings")
        } else {
            if savedSchema < 4 {
                raw.removeValue(forKey: "select")
                notes.append("schema<4: reset select")
            }
            if savedSchema < 6 {
                raw.removeValue(forKey: "siri")
                notes.append("schema<6: removed siri mapping")
            }
            if savedSchema < 7 {
                for (button, value) in raw {
                    if let action = ButtonAction(rawValue: value), action.isVoiceDictationKey {
                        raw[button] = ButtonAction.none.rawValue
                        notes.append("schema<7: cleared voice hotkey on \(button)")
                    }
                }
            }
            if savedSchema < 8 {
                raw.removeValue(forKey: "menu")
                notes.append("schema<8: reset menu")
            }
            if savedSchema < 9 {
                for key in schema9Resets {
                    raw.removeValue(forKey: key)
                }
                notes.append("schema<9: reset intended defaults \(schema9Resets.sorted())")
            }
        }

        var mappings: [String: ButtonAction] = [:]
        for (button, actionRaw) in raw {
            if let action = ButtonAction(rawValue: actionRaw) {
                mappings[button] = action
            } else {
                notes.append("dropped unparsable \(button)=\(actionRaw)")
            }
        }
        for (button, action) in defaults where mappings[button] == nil {
            mappings[button] = action
        }
        notes.append(contentsOf: sanitize(&mappings))
        return MigrationResult(mappings: mappings, schema: currentSchema, notes: notes)
    }

    @discardableResult
    static func sanitize(_ mappings: inout [String: ButtonAction]) -> [String] {
        var notes: [String] = []
        mappings.removeValue(forKey: "siri")
        for (button, action) in mappings where action.isVoiceDictationKey {
            // `.none` here would resolve to Optional.none and delete the key,
            // which re-applies the default on the next launch instead of clearing.
            mappings[button] = ButtonAction.none
            notes.append("sanitize: cleared voice hotkey on \(button)")
        }
        for (button, action) in mappings
        where action.requiresHold && action != .backspace && !holdCapableButtons.contains(button) {
            mappings[button] = ButtonAction.none
            notes.append("sanitize: cleared hold action on tap-only \(button)")
        }
        return notes
    }

    static func resetToDefaults() -> [String: ButtonAction] {
        defaults
    }
}
