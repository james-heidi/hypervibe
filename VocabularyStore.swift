//
//  VocabularyStore.swift
//  HyperVibe
//
//  User-editable custom vocabulary for CTC boosting. Plain JSON the user can
//  open in any editor; tolerant decode — malformed entries are skipped, never
//  block dictation. Reloaded when the file's mtime changes.
//

import Foundation

struct VocabularyTerm: Codable {
    let text: String
    let aliases: [String]?
}

final class VocabularyStore {
    static let shared = VocabularyStore()
    static let enabledKey = "vocabularyBoostingEnabled"

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HyperVibe/vocabulary.json")
    }()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var cachedTerms: [VocabularyTerm] = []
    private var cachedMtime: Date?

    /// Seeded on first use so 「编辑词表…」 always has a file to open.
    static let defaultTerms: [VocabularyTerm] = [
        VocabularyTerm(text: "Heidi", aliases: ["Haiti", "Heidy", "Hidey"]),
        VocabularyTerm(text: "HyperVibe", aliases: ["hyperwipe", "hyper vibe", "hyper wipe"]),
        VocabularyTerm(text: "Claude Code", aliases: ["cloud code", "clod code"]),
        VocabularyTerm(text: "Claude", aliases: ["cloud", "clod"]),
        VocabularyTerm(text: "Parakeet", aliases: ["para keet", "parrot keet"]),
        VocabularyTerm(text: "FluidAudio", aliases: ["fluid audio"]),
        VocabularyTerm(text: "OpenSpec", aliases: ["open spec"]),
        VocabularyTerm(text: "worktree", aliases: ["work tree"]),
        // Deliberately no common English words (commit, rebase, …): the CTC
        // spotter collides them with sound-alikes ("because"→"rebase").
    ]

    /// Current terms; reloads from disk when mtime changed. Seeds defaults on
    /// first call. Never throws — failures log and return the last good list.
    /// File format is FluidAudio's vocabulary config: {"terms": [{"text", "aliases"}]}.
    func terms() -> [VocabularyTerm] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.fileURL.path) {
            seedDefaults()
        }
        let mtime = (try? fm.attributesOfItem(atPath: Self.fileURL.path)[.modificationDate]) as? Date
        if let mtime, mtime == cachedMtime { return cachedTerms }
        do {
            let data = try Data(contentsOf: Self.fileURL)
            // Tolerant decode: keep valid entries, skip garbage rows.
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = obj["terms"] as? [[String: Any]] {
                var terms: [VocabularyTerm] = []
                for row in rows {
                    guard let text = row["text"] as? String, !text.isEmpty else {
                        rmDebug("📖 vocabulary: skipped malformed entry \(row)")
                        continue
                    }
                    terms.append(VocabularyTerm(text: text, aliases: row["aliases"] as? [String]))
                }
                cachedTerms = terms
                cachedMtime = mtime
            } else {
                rmDebug("📖 vocabulary: file is not a {\"terms\": [...]} config — using last good list")
            }
        } catch {
            rmDebug("📖 vocabulary load failed: \(error.localizedDescription)")
        }
        return cachedTerms
    }

    /// Content fingerprint for rebuild-on-change checks.
    var fingerprint: String {
        terms().map { "\($0.text)|\(($0.aliases ?? []).joined(separator: ","))" }
            .joined(separator: ";")
    }

    private func seedDefaults() {
        do {
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let termsData = try JSONEncoder().encode(Self.defaultTerms)
            let termsJSON = try JSONSerialization.jsonObject(with: termsData)
            // Strict thresholds: corpus-tuned 2026-07-29 — looser values made the
            // spotter replace common words ("payment"→"Parakeet") on remote audio.
            let config: [String: Any] = [
                "terms": termsJSON,
                "minSimilarity": 0.75,
                "minCtcScore": -6.0,
                "minCombinedConfidence": 0.75,
            ]
            let pretty = try JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try pretty.write(to: Self.fileURL, options: .atomic)
        } catch {
            rmDebug("📖 vocabulary seed failed: \(error.localizedDescription)")
        }
    }
}
