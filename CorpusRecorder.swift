//
//  CorpusRecorder.swift
//  HyperVibe
//
//  Opt-in dictation corpus capture for offline STT evaluation.
//  Persists the exact WAV each engine decoded plus transcripts and timing to
//  ~/Library/Application Support/HyperVibe/corpus/. Passive tap: every failure
//  is rmDebug-only and never affects the dictation path.
//

import Foundation

final class CorpusRecorder {
    static let shared = CorpusRecorder()
    static let defaultsKey = "corpusRecordingEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    static let corpusDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HyperVibe/corpus", isDirectory: true)
    }()

    private let queue = DispatchQueue(label: "com.hypervibe.corpus-recorder", qos: .utility)
    /// One dictation runs at a time, so "most recent" is enough to attach polish.
    private var lastRecordedID: String?

    /// Record from in-memory sample buffers. `samples` is what the engine
    /// decoded (post front-end); `rawPCM` is the capture before conditioning so
    /// front-end changes can be replayed offline (written as `<id>.raw.wav`).
    func record(
        pcmS16 samples: [Int16],
        rawPCM: [Int16]? = nil,
        sampleRate: Int,
        engineID: String,
        decodeMs: Int,
        rawTranscript: String,
        frontEndMode: String = AudioFrontEndMode.current.rawValue
    ) {
        guard isEnabled, !samples.isEmpty else { return }
        let id = Self.makeUtteranceID()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: Self.corpusDirectory, withIntermediateDirectories: true)
                try PCMWaveWriter.write(
                    samples: samples,
                    sampleRate: sampleRate,
                    to: Self.corpusDirectory.appendingPathComponent("\(id).wav")
                )
                if let rawPCM, !rawPCM.isEmpty {
                    try PCMWaveWriter.write(
                        samples: rawPCM,
                        sampleRate: sampleRate,
                        to: Self.corpusDirectory.appendingPathComponent("\(id).raw.wav")
                    )
                }
            } catch {
                rmDebug("🎙️ corpus clip write failed: \(error.localizedDescription)")
                return
            }
            self.lastRecordedID = id
            self.writeSidecar(id: id, [
                "id": id,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "engineID": engineID,
                "sampleRate": sampleRate,
                "sampleCount": samples.count,
                "decodeMs": decodeMs,
                "rawTranscript": rawTranscript,
                "polishedTranscript": NSNull(),
                "frontEndMode": frontEndMode,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            ])
        }
    }

    /// Short-clip-gate convenience: raw audio only (nothing was processed).
    func recordDropped(pcmS16 samples: [Int16], sampleRate: Int, engineID: String) {
        record(pcmS16: samples, sampleRate: sampleRate, engineID: engineID, decodeMs: 0, rawTranscript: "")
    }

    /// Attach the polished transcript to the most recent utterance.
    func attachPolished(_ polished: String) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self, let id = self.lastRecordedID else { return }
            let url = Self.corpusDirectory.appendingPathComponent("\(id).json")
            do {
                let data = try Data(contentsOf: url)
                guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                obj["polishedTranscript"] = polished
                try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                    .write(to: url, options: .atomic)
            } catch {
                rmDebug("🎙️ corpus polish attach failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeSidecar(id: String, _ obj: [String: Any]) {
        do {
            try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                .write(to: Self.corpusDirectory.appendingPathComponent("\(id).json"), options: .atomic)
        } catch {
            rmDebug("🎙️ corpus sidecar write failed: \(error.localizedDescription)")
        }
    }

    private static func makeUtteranceID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }
}
