//
//  TranscriptionEngine.swift
//  HyperVibe
//
//  Pluggable push-to-talk transcription backends.
//

import Foundation

enum TranscriptionEngineID: String, CaseIterable {
    case parakeet = "parakeet"
    case openAI = "openAI"

    static let defaultsKey = "transcriptionEngineID"
    static let openAIModelDefaultsKey = "transcriptionOpenAIModel"

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .parakeet: return "Parakeet 本地"
        }
    }

    static var current: TranscriptionEngineID {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let id = TranscriptionEngineID(rawValue: raw) {
                return id
            }
            // Persist migration away from removed engines (e.g. "appleSpeech").
            UserDefaults.standard.set(TranscriptionEngineID.parakeet.rawValue, forKey: defaultsKey)
            return .parakeet
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    static var openAIModel: String {
        get {
            let value = UserDefaults.standard.string(forKey: openAIModelDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
            return "gpt-4o-mini-transcribe"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: openAIModelDefaultsKey)
        }
    }

    static let openAIModelChoices = [
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
        "whisper-1",
    ]
}

enum TranscriptionEngineState: Equatable {
    case idle
    case needsSetup(String)
    case downloading(Double)
    case preparing(ModelPrepProgress)
    case ready
    case listening
    case recognizing
    case unavailable(String)

    var menuLabel: String {
        switch self {
        case .idle: return "未就绪"
        case .needsSetup(let reason): return reason
        case .downloading(let p): return String(format: "下载中 %.0f%%", p * 100)
        case .preparing(let prep): return prep.menuLabel
        case .ready: return "听写就绪"
        case .listening: return "正在听写"
        case .recognizing: return "识别中"
        case .unavailable(let reason): return reason
        }
    }

    var isDownloading: Bool {
        switch self {
        case .downloading, .preparing: return true
        default: return false
        }
    }
}

protocol TranscriptionEngine: AnyObject {
    var id: TranscriptionEngineID { get }
    var displayName: String { get }
    var state: TranscriptionEngineState { get }
    var onState: ((TranscriptionEngineState) -> Void)? { get set }

    func prepare(completion: ((Bool) -> Void)?)
    @discardableResult
    func startUtterance() -> Bool
    func append(pcmS16 samples: [Int16], sampleRate: Double)
    func finishUtterance(completion: @escaping (Result<String?, Error>) -> Void)
    func cancel()
}

enum TranscriptionEngineError: LocalizedError {
    case notReady(String)
    case missingAPIKey
    case downloadRequired
    case network(String)
    case emptyAudio
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let message): return message
        case .missingAPIKey: return "未设置 OpenAI API Key"
        case .downloadRequired: return "需要先下载 Parakeet 模型"
        case .network(let message): return message
        case .emptyAudio: return "没有捕获到有效音频"
        case .backend(let message): return message
        }
    }
}

enum TranscriptionEngineFactory {
    static func make(_ id: TranscriptionEngineID) -> TranscriptionEngine {
        switch id {
        case .openAI:
            return OpenAITranscriptionEngine()
        case .parakeet:
            return ParakeetTranscriptionEngine()
        }
    }
}

enum PCMWaveWriter {
    /// Remote HCI Opus often lands very quiet (peak ~2k). Normalize toward a
    /// usable peak so local/cloud ASR has something to work with.
    static func boostForASR(_ samples: [Int16], targetPeak: Int16 = 20_000) -> [Int16] {
        let peak = samples.reduce(0) { max($0, abs(Int32($1))) }
        guard peak > 0, peak < Int32(targetPeak) else { return samples }
        let gain = Float(targetPeak) / Float(peak)
        return samples.map { sample in
            let boosted = Float(sample) * gain
            let clipped = max(-32768.0, min(32767.0, boosted.rounded()))
            return Int16(clipped)
        }
    }

    static func write(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let dataSize = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)
        appendU16(1)
        appendU16(1)
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        data.append(contentsOf: Array("data".utf8))
        appendU32(dataSize)
        for s in samples {
            var le = s.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
    }
}
