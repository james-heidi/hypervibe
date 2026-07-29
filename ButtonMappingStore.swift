//
//  ButtonMappingStore.swift
//  HyperVibe
//
//  Defaults, sanitize, and one-shot UserDefaults → profile migration helpers.
//  Live mappings live in MappingProfileStore after migration.
//

import Foundation

enum ButtonMappingStore {
    /// Confirmed product defaults for fresh installs / adapter reset.
    static var defaults: [String: ButtonAction] { SiriRemoteLayout.defaultMappings }

    /// Buttons shown in the 按键映射 submenu — kept here so tests can catch drift
    /// against `defaults` keys.
    static var menuButtons: [(key: String, label: String)] { SiriRemoteLayout.menuButtons }

    static let currentSchema = 10

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
            if savedSchema < 10 {
                raw.removeValue(forKey: "tv")
                notes.append("schema<10: reset tv to recovery")
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

    static func encodeMappings(_ mappings: [String: ButtonAction]) -> [String: String] {
        var encoded: [String: String] = [:]
        for (button, action) in mappings {
            encoded[button] = action.rawValue
        }
        return encoded
    }

    static func decodeMappings(_ raw: [String: String]) -> [String: ButtonAction] {
        var mappings: [String: ButtonAction] = [:]
        for (button, actionRaw) in raw {
            if let action = ButtonAction(rawValue: actionRaw) {
                mappings[button] = action
            }
        }
        sanitize(&mappings)
        return mappings
    }
}
