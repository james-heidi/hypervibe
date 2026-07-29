import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MappingProfileStoreTests {
    static func main() {
        testMigrateUserDefaultsIntoDefaultProfile()
        testCreateSelectDuplicateDelete()
        testDeleteLastProfileFails()
        testImportExportRoundTrip()
        testImportDropsInvalidActions()
        testResetMappingsUsesAdapterDefaults()
        print("MappingProfileStoreTests: PASS")
    }

    private static func makeStore(
        suffix: String,
        configureDefaults: ((UserDefaults) -> Void)? = nil
    ) -> MappingProfileStore {
        let suiteName = "HyperVibe.MappingProfileStoreTests.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        configureDefaults?(defaults)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hypervibe-profiles-\(suffix)-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: url)
        return MappingProfileStore(catalogURL: url, defaults: defaults)
    }

    private static func testMigrateUserDefaultsIntoDefaultProfile() {
        let store = makeStore(suffix: "migrate") { defaults in
            defaults.set(9, forKey: MappingProfileStore.legacySchemaKey)
            defaults.set(
                ["tv": ButtonAction.ctrlC.rawValue, "ringUp": ButtonAction.downKey.rawValue],
                forKey: MappingProfileStore.legacyMappingsKey
            )
            defaults.set(true, forKey: MappingProfileStore.legacyTrackpadKey)
        }
        expect(store.profiles.count == 1, "one migrated profile")
        expect(store.activeProfile.name == "默认", "default name")
        expect(store.activeProfile.decodedMappings["tv"] == .recoverDictation, "schema10 tv reset")
        expect(store.activeProfile.decodedMappings["ringUp"] == .downKey, "preserved ringUp")
        expect(store.activeProfile.trackpadControlEnabled, "migrated trackpad")
    }

    private static func testCreateSelectDuplicateDelete() {
        let store = makeStore(suffix: "crud")
        let created = try! store.create(name: "Coding", fromCurrent: true)
        expect(store.profiles.count == 2, "create adds profile")
        expect(store.activeProfileID == created.id, "create activates")

        let originalID = store.profiles.first { $0.name == "默认" }!.id
        _ = try! store.select(id: originalID)
        expect(store.activeProfile.name == "默认", "select works")

        let dup = try! store.duplicate(id: created.id)
        expect(dup.name.contains("副本"), "duplicate name")
        expect(store.profiles.count == 3, "duplicate adds")

        _ = try! store.rename(id: dup.id, to: "Renamed")
        expect(store.profiles.contains { $0.id == dup.id && $0.name == "Renamed" }, "rename")

        try! store.delete(id: dup.id)
        expect(store.profiles.count == 2, "delete removes")
        expect(!store.profiles.contains { $0.id == dup.id }, "deleted gone")
    }

    private static func testDeleteLastProfileFails() {
        let store = makeStore(suffix: "last")
        var threw = false
        do {
            try store.delete(id: store.activeProfileID)
        } catch MappingProfileStoreError.lastProfile {
            threw = true
        } catch {
            fputs("FAIL: unexpected error \(error)\n", stderr)
            exit(1)
        }
        expect(threw, "last profile protected")
        expect(store.profiles.count == 1, "still one profile")
    }

    private static func testImportExportRoundTrip() {
        let store = makeStore(suffix: "io")
        store.updateActive(
            mappings: ["tv": .escKey, "menu": .enterKey],
            trackpadControlEnabled: true,
            scrollSpeed: .fast
        )
        let exported = try! store.exportActiveJSON()
        let other = makeStore(suffix: "io-other")
        let result = try! other.importJSON(exported)
        expect(result.importedIDs.count == 1, "imported one")
        expect(other.activeProfile.decodedMappings["tv"] == .escKey, "imported mapping")
        expect(other.activeProfile.trackpadControlEnabled, "imported trackpad")
        expect(other.activeProfile.decodedScrollSpeed == .fast, "imported scroll")

        let catalogData = try! store.exportCatalogJSON()
        let third = makeStore(suffix: "io-catalog")
        let catalogResult = try! third.importJSON(catalogData)
        expect(catalogResult.importedIDs.count == store.profiles.count, "catalog import count")
    }

    private static func testImportDropsInvalidActions() {
        let store = makeStore(suffix: "invalid")
        let payload = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Broken",
          "mappings": {
            "tv": "not-a-real-action",
            "playPause": "Space: Claude Voice Dictation",
            "menu": "Esc: Navigate Back"
          },
          "trackpadControlEnabled": false,
          "scrollSpeed": "Medium",
          "updatedAt": "2026-07-29T00:00:00Z"
        }
        """.data(using: .utf8)!
        _ = try! store.importJSON(payload)
        let imported = store.activeProfile
        expect(imported.decodedMappings["tv"] == .recoverDictation, "invalid → default filled")
        expect(imported.decodedMappings["playPause"] == ButtonAction.none, "voice hotkey sanitized")
        expect(imported.decodedMappings["menu"] == .escKey, "valid kept")
    }

    private static func testResetMappingsUsesAdapterDefaults() {
        let store = makeStore(suffix: "reset")
        store.updateActive(mappings: ["tv": .ctrlC, "menu": .enterKey])
        RemoteAdapterRegistry.setActive(productID: 0x0314)
        let reset = store.resetActiveMappingsToAdapterDefaults()
        expect(reset.decodedMappings["tv"] == .recoverDictation, "adapter default tv")
        expect(reset.decodedMappings["menu"] == .commandBackspace, "adapter default menu")
        RemoteAdapterRegistry.setActive(productID: nil)
    }
}
