//
//  MappingProfileStore.swift
//  HyperVibe
//
//  Named local profiles for button mappings + trackpad + scroll.
//  Catalog is JSON under Application Support; UserDefaults mappings migrate once.
//

import CoreGraphics
import Foundation

/// Trackpad two-finger scroll scale (persisted inside mapping profiles).
enum ScrollSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"

    var scale: CGFloat {
        switch self {
        case .slow: return 150.0
        case .medium: return 300.0
        case .fast: return 500.0
        }
    }
}

struct MappingProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var mappings: [String: String]
    var trackpadControlEnabled: Bool
    var scrollSpeed: String
    /// Swipe gesture mappings (direction rawValue → SwipeAction rawValue).
    /// Optional so pre-gesture profile JSON decodes untouched; nil resolves to
    /// the bound remote model's defaults.
    var swipeMappings: [String: String]?
    var updatedAt: Date

    static func make(
        name: String,
        mappings: [String: ButtonAction],
        trackpadControlEnabled: Bool,
        scrollSpeed: ScrollSpeed,
        swipeMappings: [SwipeDirection: SwipeAction]? = nil,
        id: UUID = UUID()
    ) -> MappingProfile {
        MappingProfile(
            id: id,
            name: name,
            mappings: ButtonMappingStore.encodeMappings(mappings),
            trackpadControlEnabled: trackpadControlEnabled,
            scrollSpeed: scrollSpeed.rawValue,
            swipeMappings: swipeMappings.map(Self.encodeSwipes),
            updatedAt: Date()
        )
    }

    static func encodeSwipes(_ swipes: [SwipeDirection: SwipeAction]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: swipes.map { ($0.key.rawValue, $0.value.rawValue) })
    }

    /// nil when the profile predates gestures — caller resolves model defaults.
    var decodedSwipeMappings: [SwipeDirection: SwipeAction]? {
        guard let swipeMappings else { return nil }
        var out: [SwipeDirection: SwipeAction] = [:]
        for (rawDirection, rawAction) in swipeMappings {
            guard let direction = SwipeDirection(rawValue: rawDirection),
                  let action = SwipeAction(rawValue: rawAction) else { continue }
            out[direction] = action
        }
        return out
    }

    var decodedMappings: [String: ButtonAction] {
        ButtonMappingStore.decodeMappings(mappings)
    }

    var decodedScrollSpeed: ScrollSpeed {
        ScrollSpeed(rawValue: scrollSpeed) ?? .medium
    }

    mutating func apply(
        mappings: [String: ButtonAction]? = nil,
        trackpadControlEnabled: Bool? = nil,
        scrollSpeed: ScrollSpeed? = nil,
        swipeMappings: [SwipeDirection: SwipeAction]? = nil,
        name: String? = nil
    ) {
        if let swipeMappings {
            self.swipeMappings = Self.encodeSwipes(swipeMappings)
        }
        if let mappings {
            var sanitized = mappings
            _ = ButtonMappingStore.sanitize(&sanitized)
            self.mappings = ButtonMappingStore.encodeMappings(sanitized)
        }
        if let trackpadControlEnabled {
            self.trackpadControlEnabled = trackpadControlEnabled
        }
        if let scrollSpeed {
            self.scrollSpeed = scrollSpeed.rawValue
        }
        if let name {
            self.name = name
        }
        updatedAt = Date()
    }
}

struct ProfileCatalog: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int
    /// Legacy/global pointer — still written so older builds keep working, and
    /// used to seed the first per-model binding.
    var activeProfileID: UUID
    /// Per-remote-model bindings (RemoteModel.rawValue → profile id). Each model
    /// keeps its own active profile so A2540/A2854 configs never bleed.
    var activeProfileByModel: [String: UUID]? = nil
    var profiles: [MappingProfile]

    var activeProfile: MappingProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    func profileID(for model: RemoteModel) -> UUID? {
        activeProfileByModel?[model.rawValue]
    }

    mutating func bind(_ id: UUID, to model: RemoteModel) {
        var map = activeProfileByModel ?? [:]
        map[model.rawValue] = id
        activeProfileByModel = map
    }
}

enum MappingProfileStoreError: LocalizedError {
    case lastProfile
    case notFound
    case emptyCatalog
    case invalidJSON
    case emptyName

    var errorDescription: String? {
        switch self {
        case .lastProfile: return "至少保留一个配置档"
        case .notFound: return "找不到该配置档"
        case .emptyCatalog: return "配置档列表为空"
        case .invalidJSON: return "无法解析配置档 JSON"
        case .emptyName: return "名称不能为空"
        }
    }
}

final class MappingProfileStore {
    static let shared = MappingProfileStore()

    static let migratedDefaultsKey = "mappingProfilesMigrated"
    static let legacyMappingsKey = "buttonMappings"
    static let legacySchemaKey = "buttonMappingsSchema"
    static let legacyTrackpadKey = "trackpadControlEnabled"

    private let catalogURL: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var catalog: ProfileCatalog

    static let legacySwipeMappingsKey = "swipeMappings"

    var profiles: [MappingProfile] { catalog.profiles }

    /// Remote model whose binding is currently in effect. Updated on connect;
    /// fallback model keeps the legacy pointer semantics when nothing is paired.
    private(set) var currentModel: RemoteModel = RemoteAdapterRegistry.fallbackAdapter.model

    /// Effective active profile id: per-model binding first, legacy pointer second.
    var activeProfileID: UUID {
        if let bound = catalog.profileID(for: currentModel),
           catalog.profiles.contains(where: { $0.id == bound }) {
            return bound
        }
        return catalog.activeProfileID
    }

    var activeProfile: MappingProfile {
        if let active = catalog.profiles.first(where: { $0.id == activeProfileID }) ?? catalog.activeProfile {
            return active
        }
        // Should be unreachable after load/bootstrap.
        return makeSeedProfile(name: "默认")
    }

    /// Swipe mappings in effect for the active profile: explicit values, else
    /// the bound model's defaults (A2540 → gesture-era set, others → none).
    var activeSwipeMappings: [SwipeDirection: SwipeAction] {
        activeProfile.decodedSwipeMappings ?? SwipeAction.defaults(for: currentModel)
    }

    /// Bind the connected remote model, seeding a model default profile on first
    /// contact: A2854 keeps whatever is already active (current behavior);
    /// A2540 gets the gesture-era configuration.
    @discardableResult
    func bind(model: RemoteModel) -> MappingProfile {
        currentModel = model
        if let bound = catalog.profileID(for: model),
           catalog.profiles.contains(where: { $0.id == bound }) {
            migrateLegacySwipeDefaultsIfNeeded()
            return activeProfile
        }
        let seedID: UUID
        if model == .a2540 {
            let seed = MappingProfile.make(
                name: uniqueName(base: "A2540 默认"),
                mappings: RemoteAdapterRegistry.a2540.defaultMappings,
                trackpadControlEnabled: false,
                scrollSpeed: .medium,
                swipeMappings: SwipeAction.a2540Defaults
            )
            catalog.profiles.append(seed)
            seedID = seed.id
        } else {
            // A2854/unknown: preserve current behavior — bind the legacy pointer.
            seedID = catalog.activeProfileID
        }
        catalog.bind(seedID, to: model)
        migrateLegacySwipeDefaultsIfNeeded()
        save()
        return activeProfile
    }

    /// One-time migration of pre-profile UserDefaults swipe mappings into the
    /// bound profile (only when the profile has no swipe mappings of its own).
    private func migrateLegacySwipeDefaultsIfNeeded() {
        guard let legacy = defaults.dictionary(forKey: Self.legacySwipeMappingsKey) as? [String: String],
              !legacy.isEmpty else { return }
        defaults.removeObject(forKey: Self.legacySwipeMappingsKey)
        guard let index = indexOfActive(), catalog.profiles[index].swipeMappings == nil else { return }
        catalog.profiles[index].swipeMappings = legacy
        catalog.profiles[index].updatedAt = Date()
        save()
        rmDebug("🎮 migrated legacy swipe mappings into profile \(catalog.profiles[index].name)")
    }

    init(
        catalogURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        if let catalogURL {
            self.catalogURL = catalogURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dir = support.appendingPathComponent("HyperVibe", isDirectory: true)
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            self.catalogURL = dir.appendingPathComponent("profiles.json")
        }
        self.catalog = ProfileCatalog(
            schema: ProfileCatalog.currentSchema,
            activeProfileID: UUID(),
            profiles: []
        )
        self.catalog = loadOrMigrate()
    }

    // MARK: - Persistence

    @discardableResult
    private func loadOrMigrate() -> ProfileCatalog {
        if let existing = readCatalogFile() {
            return normalize(existing)
        }
        let migrated = migrateFromUserDefaults()
        writeCatalog(migrated)
        defaults.set(true, forKey: Self.migratedDefaultsKey)
        return migrated
    }

    private func readCatalogFile() -> ProfileCatalog? {
        guard fileManager.fileExists(atPath: catalogURL.path),
              let data = try? Data(contentsOf: catalogURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProfileCatalog.self, from: data)
    }

    private func writeCatalog(_ catalog: ProfileCatalog) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(catalog) else { return }
        try? fileManager.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: catalogURL, options: .atomic)
    }

    private func save() {
        writeCatalog(catalog)
    }

    private func normalize(_ catalog: ProfileCatalog) -> ProfileCatalog {
        var next = catalog
        next.schema = ProfileCatalog.currentSchema
        if next.profiles.isEmpty {
            let seed = makeSeedProfile(name: "默认")
            next.profiles = [seed]
            next.activeProfileID = seed.id
        } else if !next.profiles.contains(where: { $0.id == next.activeProfileID }) {
            next.activeProfileID = next.profiles[0].id
        }
        if var map = next.activeProfileByModel {
            for (model, bound) in map where !next.profiles.contains(where: { $0.id == bound }) {
                map[model] = nil
            }
            next.activeProfileByModel = map.isEmpty ? nil : map
        }
        for index in next.profiles.indices {
            var mappings = next.profiles[index].decodedMappings
            for (button, action) in ButtonMappingStore.defaults where mappings[button] == nil {
                mappings[button] = action
            }
            _ = ButtonMappingStore.sanitize(&mappings)
            next.profiles[index].mappings = ButtonMappingStore.encodeMappings(mappings)
        }
        return next
    }

    private func migrateFromUserDefaults() -> ProfileCatalog {
        let savedSchema = defaults.integer(forKey: Self.legacySchemaKey)
        let saved = defaults.dictionary(forKey: Self.legacyMappingsKey) as? [String: String]
        let result = ButtonMappingStore.migrate(saved: saved, savedSchema: savedSchema)
        for note in result.notes {
            rmDebug("🎮 profile migrate: \(note)")
        }
        let trackpad: Bool
        if defaults.object(forKey: Self.legacyTrackpadKey) == nil {
            trackpad = false
        } else {
            trackpad = defaults.bool(forKey: Self.legacyTrackpadKey)
        }
        let profile = MappingProfile.make(
            name: "默认",
            mappings: result.mappings,
            trackpadControlEnabled: trackpad,
            scrollSpeed: .medium
        )
        defaults.set(result.schema, forKey: Self.legacySchemaKey)
        return ProfileCatalog(
            schema: ProfileCatalog.currentSchema,
            activeProfileID: profile.id,
            profiles: [profile]
        )
    }

    private func makeSeedProfile(name: String) -> MappingProfile {
        MappingProfile.make(
            name: name,
            mappings: ButtonMappingStore.defaults,
            trackpadControlEnabled: false,
            scrollSpeed: .medium
        )
    }

    private func uniqueName(base: String, excluding: UUID? = nil) -> String {
        let existing = Set(catalog.profiles.compactMap { profile -> String? in
            guard profile.id != excluding else { return nil }
            return profile.name
        })
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func indexOfActive() -> Int? {
        catalog.profiles.firstIndex { $0.id == activeProfileID }
    }

    // MARK: - Mutations

    @discardableResult
    func select(id: UUID) throws -> MappingProfile {
        guard catalog.profiles.contains(where: { $0.id == id }) else {
            throw MappingProfileStoreError.notFound
        }
        // Selection binds the CONNECTED model only; legacy pointer follows for
        // old-build compatibility. Other models' bindings are untouched.
        catalog.bind(id, to: currentModel)
        catalog.activeProfileID = id
        save()
        return activeProfile
    }

    @discardableResult
    func create(name: String, fromCurrent: Bool) throws -> MappingProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MappingProfileStoreError.emptyName }
        let finalName = uniqueName(base: trimmed)
        let profile: MappingProfile
        if fromCurrent {
            var current = activeProfile
            current.id = UUID()
            current.name = finalName
            current.updatedAt = Date()
            profile = current
        } else {
            profile = makeSeedProfile(name: finalName)
        }
        catalog.profiles.append(profile)
        catalog.activeProfileID = profile.id
        catalog.bind(profile.id, to: currentModel)
        save()
        return profile
    }

    @discardableResult
    func rename(id: UUID, to name: String) throws -> MappingProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MappingProfileStoreError.emptyName }
        guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else {
            throw MappingProfileStoreError.notFound
        }
        catalog.profiles[index].name = uniqueName(base: trimmed, excluding: id)
        catalog.profiles[index].updatedAt = Date()
        save()
        return catalog.profiles[index]
    }

    @discardableResult
    func duplicate(id: UUID) throws -> MappingProfile {
        guard let source = catalog.profiles.first(where: { $0.id == id }) else {
            throw MappingProfileStoreError.notFound
        }
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName(base: "\(source.name) 副本")
        copy.updatedAt = Date()
        catalog.profiles.append(copy)
        catalog.activeProfileID = copy.id
        catalog.bind(copy.id, to: currentModel)
        save()
        return copy
    }

    func delete(id: UUID) throws {
        guard catalog.profiles.count > 1 else {
            throw MappingProfileStoreError.lastProfile
        }
        guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else {
            throw MappingProfileStoreError.notFound
        }
        catalog.profiles.remove(at: index)
        if catalog.activeProfileID == id {
            catalog.activeProfileID = catalog.profiles[0].id
        }
        // Repoint any model binding that referenced the deleted profile.
        if var map = catalog.activeProfileByModel {
            for (model, bound) in map where bound == id {
                map[model] = catalog.profiles[0].id
            }
            catalog.activeProfileByModel = map
        }
        save()
    }

    /// Reset active profile mappings to the active adapter's device defaults.
    @discardableResult
    func resetActiveMappingsToAdapterDefaults() -> MappingProfile {
        guard let index = indexOfActive() else {
            let seed = makeSeedProfile(name: "默认")
            catalog = ProfileCatalog(
                schema: ProfileCatalog.currentSchema,
                activeProfileID: seed.id,
                profiles: [seed]
            )
            save()
            return seed
        }
        catalog.profiles[index].apply(
            mappings: RemoteAdapterRegistry.activeAdapter.defaultMappings
        )
        save()
        return catalog.profiles[index]
    }

    func updateActive(
        mappings: [String: ButtonAction]? = nil,
        trackpadControlEnabled: Bool? = nil,
        scrollSpeed: ScrollSpeed? = nil,
        swipeMappings: [SwipeDirection: SwipeAction]? = nil
    ) {
        guard let index = indexOfActive() else { return }
        catalog.profiles[index].apply(
            mappings: mappings,
            trackpadControlEnabled: trackpadControlEnabled,
            scrollSpeed: scrollSpeed,
            swipeMappings: swipeMappings
        )
        save()
    }

    // MARK: - Import / Export

    struct ImportResult {
        var importedIDs: [UUID]
        var notes: [String]
    }

    @discardableResult
    func importJSON(_ data: Data, activateFirst: Bool = true) throws -> ImportResult {
        let incoming = try Self.parseImportProfiles(data)
        var notes: [String] = []

        var importedIDs: [UUID] = []
        var knownIDs = Set(catalog.profiles.map(\.id))
        for var profile in incoming {
            if knownIDs.contains(profile.id) {
                notes.append("id conflict for \(profile.name) — assigned new id")
                profile.id = UUID()
            }
            knownIDs.insert(profile.id)
            var mappings = profile.decodedMappings
            for (button, action) in ButtonMappingStore.defaults where mappings[button] == nil {
                mappings[button] = action
            }
            let sanitizeNotes = ButtonMappingStore.sanitize(&mappings)
            notes.append(contentsOf: sanitizeNotes)
            profile.mappings = ButtonMappingStore.encodeMappings(mappings)
            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.name = uniqueName(base: "导入")
            } else {
                profile.name = uniqueName(base: profile.name)
            }
            profile.updatedAt = Date()
            catalog.profiles.append(profile)
            importedIDs.append(profile.id)
        }

        guard !importedIDs.isEmpty else {
            throw MappingProfileStoreError.invalidJSON
        }
        if activateFirst, let first = importedIDs.first {
            catalog.activeProfileID = first
        }
        save()
        return ImportResult(importedIDs: importedIDs, notes: notes)
    }

    func exportActiveJSON() throws -> Data {
        try encodeJSON(activeProfile)
    }

    func exportCatalogJSON() throws -> Data {
        try encodeJSON(catalog)
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func parseImportProfiles(_ data: Data) throws -> [MappingProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let catalog = try? decoder.decode(ProfileCatalog.self, from: data),
           !catalog.profiles.isEmpty {
            return catalog.profiles
        }
        if let profile = try? decoder.decode(MappingProfile.self, from: data) {
            return [profile]
        }
        struct ProfilesOnly: Codable {
            var profiles: [MappingProfile]
        }
        if let wrapper = try? decoder.decode(ProfilesOnly.self, from: data),
           !wrapper.profiles.isEmpty {
            return wrapper.profiles
        }
        throw MappingProfileStoreError.invalidJSON
    }
}
