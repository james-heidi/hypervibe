//
//  RemoteAdapter.swift
//  HyperVibe
//
//  Per-device HID → logical-button adapters. Shared code consumes LogicalButton
//  (or its string raw value); product-ID lists and identify tables live here.
//

import Foundation

enum RemoteModel: String, Codable, CaseIterable {
    case a2540
    case a2854
    case unknown
}

/// Stable string keys used in profiles and menus. New remotes map HID into these.
enum LogicalButton: String, CaseIterable {
    case menu
    case tv
    case select
    case ringUp
    case ringDown
    case ringLeft
    case ringRight
    case playPause
    case volumeUp
    case volumeDown
    case mute
    case siri
    case nextTrack
    case prevTrack
    case back
    case power
}

protocol RemoteAdapter {
    var model: RemoteModel { get }
    var productIDs: Set<Int> { get }
    var displayName: String { get }
    func identifyButton(page: UInt32, usage: UInt32) -> LogicalButton?
    var menuButtons: [(key: String, label: String)] { get }
    var holdCapableButtons: Set<String> { get }
    var defaultMappings: [String: ButtonAction] { get }
}

/// Shared Siri Remote HID table + menu/hold defaults. A2540 and A2854 start identical;
/// diverge in a concrete adapter when a model-specific usage is confirmed.
enum SiriRemoteLayout {
    /// Product IDs that are Siri / Apple TV remotes but not a dedicated adapter.
    static let legacyProductIDs: Set<Int> = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x0269,
        0x0C4E, 0x0C4F, 0x030D, 0x030E,
    ]

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

    static let holdCapableButtons: Set<String> = [
        "playPause", "volumeUp", "volumeDown",
        "ringUp", "ringDown", "ringLeft", "ringRight", "mute",
        "siri",
    ]

    static let defaultMappings: [String: ButtonAction] = [
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
        "tv": .recoverDictation,
    ]

    static func identifyButton(page: UInt32, usage: UInt32) -> LogicalButton? {
        switch (page, usage) {
        case (0x01, 0x86): return .menu
        case (0x01, 0x40): return .menu

        case (0x0C, 0x04): return .siri
        case (0x0C, 0x60): return .tv
        case (0x0C, 0x80): return .select
        case (0x0C, 0x41): return .select
        case (0x0C, 0x42): return .ringUp
        case (0x0C, 0x43): return .ringDown
        case (0x0C, 0x44): return .ringLeft
        case (0x0C, 0x45): return .ringRight
        case (0x0C, 0xCD): return .playPause
        case (0x0C, 0xE2): return .mute
        case (0x0C, 0xE9): return .volumeUp
        case (0x0C, 0xEA): return .volumeDown
        case (0x0C, 0xB5): return .nextTrack
        case (0x0C, 0xB6): return .prevTrack
        case (0x0C, 0x223): return .tv
        case (0x0C, 0x224): return .back
        case (0x0C, 0x40): return .menu
        case (0x0C, 0x30): return .power
        case (0x0C, 0x20): return .mute

        case (0x09, 0x01): return .select

        case (0xFF00, 0x01): return .siri
        case (0xFF00, 0x02): return .siri
        case (0xFF00, 0x03): return .siri
        case (0xFF00, _): return .siri

        case (0x0B, 0x21): return .siri
        case (0x0B, 0x2F): return .siri

        default: return nil
        }
    }
}

struct A2540Adapter: RemoteAdapter {
    let model: RemoteModel = .a2540
    let productIDs: Set<Int> = [0x0314]
    let displayName = "Siri Remote (A2540)"

    func identifyButton(page: UInt32, usage: UInt32) -> LogicalButton? {
        SiriRemoteLayout.identifyButton(page: page, usage: usage)
    }

    var menuButtons: [(key: String, label: String)] { SiriRemoteLayout.menuButtons }
    var holdCapableButtons: Set<String> { SiriRemoteLayout.holdCapableButtons }
    var defaultMappings: [String: ButtonAction] { SiriRemoteLayout.defaultMappings }
}

struct A2854Adapter: RemoteAdapter {
    let model: RemoteModel = .a2854
    let productIDs: Set<Int> = [0x0315]
    let displayName = "Siri Remote (A2854)"

    func identifyButton(page: UInt32, usage: UInt32) -> LogicalButton? {
        SiriRemoteLayout.identifyButton(page: page, usage: usage)
    }

    var menuButtons: [(key: String, label: String)] { SiriRemoteLayout.menuButtons }
    var holdCapableButtons: Set<String> { SiriRemoteLayout.holdCapableButtons }
    var defaultMappings: [String: ButtonAction] { SiriRemoteLayout.defaultMappings }
}

/// Legacy / unrecognized Apple remotes — same HID table, no model-specific defaults.
struct UnknownRemoteAdapter: RemoteAdapter {
    let model: RemoteModel = .unknown
    let productIDs: Set<Int> = SiriRemoteLayout.legacyProductIDs
    let displayName = "Siri Remote"

    func identifyButton(page: UInt32, usage: UInt32) -> LogicalButton? {
        SiriRemoteLayout.identifyButton(page: page, usage: usage)
    }

    var menuButtons: [(key: String, label: String)] { SiriRemoteLayout.menuButtons }
    var holdCapableButtons: Set<String> { SiriRemoteLayout.holdCapableButtons }
    var defaultMappings: [String: ButtonAction] { SiriRemoteLayout.defaultMappings }
}

enum RemoteAdapterRegistry {
    static let a2540: RemoteAdapter = A2540Adapter()
    static let a2854: RemoteAdapter = A2854Adapter()
    static let unknown: RemoteAdapter = UnknownRemoteAdapter()

    /// Used for menus / reset when no remote is connected.
    static let fallbackAdapter: RemoteAdapter = a2854

    private static let lock = NSLock()
    private static var _activeAdapter: RemoteAdapter = fallbackAdapter

    static var activeAdapter: RemoteAdapter {
        lock.lock()
        defer { lock.unlock() }
        return _activeAdapter
    }

    static var allKnownProductIDs: Set<Int> {
        a2540.productIDs
            .union(a2854.productIDs)
            .union(unknown.productIDs)
    }

    static func adapter(forProductID id: Int) -> RemoteAdapter {
        if a2540.productIDs.contains(id) { return a2540 }
        if a2854.productIDs.contains(id) { return a2854 }
        if unknown.productIDs.contains(id) { return unknown }
        return unknown
    }

    /// `nil` product ID means disconnected — fall back to A2854-style layout.
    static func setActive(productID: Int?) {
        let next: RemoteAdapter
        if let productID {
            next = adapter(forProductID: productID)
        } else {
            next = fallbackAdapter
        }
        lock.lock()
        _activeAdapter = next
        lock.unlock()
        rmDebug("🎮 active remote adapter=\(next.model.rawValue) product=\(productID.map { String(format: "0x%X", $0) } ?? "nil")")
    }
}
