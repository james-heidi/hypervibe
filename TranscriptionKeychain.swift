//
//  TranscriptionKeychain.swift
//  HyperVibe
//

import Foundation
import Security

enum TranscriptionKeychain {
    private static let service = "com.hypervibe.transcription"
    private static let openAIAccount = "openai-api-key"

    /// Keychain reads can block for as long as it takes the user to answer a
    /// SecurityAgent prompt (re-signing the app invalidates the stored ACL). The
    /// menu therefore reads this snapshot instead of hitting the Keychain on main.
    private static let presenceLock = NSLock()
    private static var cachedPresence = false
    /// One prompt-blocked read at a time instead of a thread per caller.
    static let keychainQueue = DispatchQueue(label: "com.hypervibe.keychain-read")

    static var hasOpenAIKeyCached: Bool {
        presenceLock.lock()
        defer { presenceLock.unlock() }
        return cachedPresence
    }

    private static func setPresence(_ present: Bool) {
        presenceLock.lock()
        cachedPresence = present
        presenceLock.unlock()
    }

    /// Resolve key presence off the main thread, then report whether it changed.
    static func refreshOpenAIKeyPresence(completion: ((Bool) -> Void)? = nil) {
        let before = hasOpenAIKeyCached
        withOpenAIKey { key in
            let changed = (key != nil) != before
            if let completion {
                DispatchQueue.main.async { completion(changed) }
            }
        }
    }

    /// Read the key off the main thread, serialized, refreshing the snapshot.
    static func withOpenAIKey(_ body: @escaping (String?) -> Void) {
        keychainQueue.async {
            let key = loadOpenAIKey()
            setPresence(key != nil)
            body(key)
        }
    }

    static func saveOpenAIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: openAIAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TranscriptionEngineError.backend("Keychain save failed (\(status))")
        }
        setPresence(true)
    }

    static func loadOpenAIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: openAIAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func deleteOpenAIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: openAIAccount,
        ]
        SecItemDelete(query as CFDictionary)
        setPresence(false)
    }

    /// Blocking check — only for background paths (transcription, polish).
    static var hasOpenAIKey: Bool { loadOpenAIKey() != nil }
}
