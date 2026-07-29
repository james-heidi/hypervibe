//
//  parakeet-eval — replay a HyperVibe dictation corpus through an ASR engine.
//
//  Usage:
//    parakeet-eval --corpus <dir> [--out hypotheses.json]
//                  [--engine parakeet|cohere]
//                  [--frontend legacy|conditioned]   (replays *.raw.wav re-conditioned)
//                  [--vocabulary vocabulary.json]    (parakeet only: CTC boosting A/B)
//
//  Emits one row per WAV: {"id", "text", "decodeMs"}.
//  Parakeet config MUST mirror ParakeetTranscriptionEngine.swift in the app
//  (v3, melChunkContext=false, dualDecodeArbitration=true) — keep in sync.
//

import AVFAudio
import Foundation
import FluidAudio

struct Hypothesis: Codable {
    let id: String
    let text: String
    let decodeMs: Int
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Args

var corpusPath: String?
var outPath = "hypotheses.json"
var engineName = "parakeet"
var frontendMode: AudioFrontEndMode?
var vocabularyPath: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--corpus": corpusPath = args.isEmpty ? nil : args.removeFirst()
    case "--out": outPath = args.isEmpty ? outPath : args.removeFirst()
    case "--engine": engineName = args.isEmpty ? engineName : args.removeFirst()
    case "--frontend":
        let raw = args.isEmpty ? "" : args.removeFirst()
        guard let mode = AudioFrontEndMode(rawValue: raw) else { fail("--frontend legacy|conditioned") }
        frontendMode = mode
    case "--vocabulary": vocabularyPath = args.isEmpty ? nil : args.removeFirst()
    default: fail("unknown argument \(arg)")
    }
}
guard let corpusPath else {
    fail("usage: parakeet-eval --corpus <dir> [--out f.json] [--engine parakeet|cohere] [--frontend legacy|conditioned] [--vocabulary v.json]")
}
guard ["parakeet", "cohere"].contains(engineName) else { fail("--engine parakeet|cohere") }

// MARK: - Corpus enumeration
// Default: replay processed `<id>.wav`. With --frontend: replay `<id>.raw.wav`
// re-conditioned through the requested chain (falls back to processed WAV when
// no raw file exists, e.g. pre-Phase-2 recordings).

let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
let allFiles = (try? FileManager.default.contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil)) ?? []
let processedWavs = allFiles
    .filter { $0.pathExtension.lowercased() == "wav" && !$0.lastPathComponent.hasSuffix(".raw.wav") }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !processedWavs.isEmpty else { fail("no .wav files in \(corpusPath)") }

func readWavInt16(_ url: URL) throws -> ([Int16], Int) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "eval", code: 1)
    }
    try file.read(into: buf)
    let n = Int(buf.frameLength)
    var out = [Int16](repeating: 0, count: n)
    if let i16 = buf.int16ChannelData {
        for i in 0..<n { out[i] = i16[0][i] }
    } else if let f32 = buf.floatChannelData {
        for i in 0..<n { out[i] = Int16(max(-32768.0, min(32767.0, (f32[0][i] * 32767.0).rounded()))) }
    }
    return (out, Int(format.sampleRate))
}

/// Load samples for one utterance honoring --frontend.
func loadUtterance(_ processedURL: URL) throws -> ([Int16], Int) {
    guard let mode = frontendMode else { return try readWavInt16(processedURL) }
    let id = processedURL.deletingPathExtension().lastPathComponent
    let rawURL = corpusURL.appendingPathComponent("\(id).raw.wav")
    if FileManager.default.fileExists(atPath: rawURL.path) {
        let (raw, rate) = try readWavInt16(rawURL)
        return (AudioFrontEnd.process(raw, sampleRate: rate, mode: mode), rate)
    }
    log("note: \(id) has no .raw.wav — using processed audio as-is")
    return try readWavInt16(processedURL)
}

func floatBuffer48k(_ samples: [Int16], sampleRate: Int) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let ch = buffer.floatChannelData?[0] {
        for i in 0..<samples.count { ch[i] = Float(samples[i]) / 32768.0 }
    }
    return buffer
}

/// 48 kHz Int16 → 16 kHz Float via FluidAudio's own resampler (same path the
/// ASR engines use internally — proper anti-aliasing, unlike naive decimation).
let sharedConverter = AudioConverter()
func decimateTo16k(_ samples: [Int16]) -> [Float] {
    let f = samples.map { Float($0) / 32768.0 }
    return (try? sharedConverter.resample(f, from: 48_000)) ?? []
}

// MARK: - Run

let semaphore = DispatchSemaphore(value: 0)
var hypotheses: [Hypothesis] = []
var runError: Error?

Task {
    do {
        switch engineName {
        case "parakeet":
            let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
            guard AsrModels.modelsExist(at: cacheDir, version: .v3) else {
                fail("Parakeet v3 models not cached at \(cacheDir.path) — download via the HyperVibe menu")
            }
            let models = try await AsrModels.load(from: cacheDir, version: .v3)
            let manager = AsrManager(config: ASRConfig(
                melChunkContext: false,
                dualDecodeArbitration: true
            ))
            try await manager.loadModels(models)

            // Optional vocabulary boosting (mirror of the app's fail-open path).
            var spotter: CtcKeywordSpotter?
            var rescorer: VocabularyRescorer?
            var vocabContext: CustomVocabularyContext?
            if let vocabularyPath {
                if !CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory()) {
                    log("downloading CTC boosting models (first run)…")
                }
                // loadWithCtcTokens tokenizes terms for the CTC head (required
                // for spotting) and honors thresholds set in the JSON config.
                let (context, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabularyPath)
                let sp = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
                spotter = sp
                // Match the app: rescue pass off (over-fires on quiet remote audio).
                rescorer = try await VocabularyRescorer.create(
                    spotter: sp, vocabulary: context,
                    config: VocabularyRescorer.Config(spotterRescueEnabled: false))
                vocabContext = context
            }

            for (index, wav) in processedWavs.enumerated() {
                let id = wav.deletingPathExtension().lastPathComponent
                let (samples, rate) = try loadUtterance(wav)
                guard let buffer = floatBuffer48k(samples, sampleRate: rate) else { continue }
                var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
                let start = Date()
                let result = try await manager.transcribe(buffer, decoderState: &decoderState)
                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let spotter, let rescorer, let vocabContext, !text.isEmpty {
                    let timings = result.tokenTimings ?? []
                    if timings.isEmpty {
                        log("  vocab: no tokenTimings from ASR — boost skipped")
                    } else {
                        let spot = try await spotter.spotKeywordsWithLogProbs(
                            audioSamples: decimateTo16k(samples), customVocabulary: vocabContext, minScore: nil)
                        log("  vocab: detections=\(spot.detections.count) frames=\(spot.totalFrames)")
                        if !spot.logProbs.isEmpty {
                            let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabContext.terms.count)
                            let out = rescorer.ctcTokenRescore(
                                transcript: text, tokenTimings: timings,
                                logProbs: spot.logProbs, frameDuration: spot.frameDuration,
                                cbw: sizeConfig.cbw,
                                minSimilarity: max(sizeConfig.minSimilarity, vocabContext.minSimilarity))
                            if out.wasModified { text = out.text }
                        }
                    }
                }
                let decodeMs = Int(Date().timeIntervalSince(start) * 1000)
                hypotheses.append(Hypothesis(id: id, text: text, decodeMs: decodeMs))
                log("[\(index + 1)/\(processedWavs.count)] \(id) \(decodeMs)ms \(text.prefix(60))")
            }

        case "cohere":
            let downloadRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HyperVibe/eval-models/cohere-transcribe")
            // ModelHub nests the repo folder name under the target directory.
            let cohereDir = downloadRoot.appendingPathComponent("cohere-transcribe/q8")
            let required = ModelNames.CohereTranscribe.requiredModels
            let present = required.allSatisfy {
                FileManager.default.fileExists(atPath: cohereDir.appendingPathComponent($0).path)
            }
            if !present {
                log("downloading Cohere Transcribe CoreML models (first run)…")
                try await ModelHub.download(.cohereTranscribeCoreml, to: downloadRoot)
            }
            let models = try await CoherePipeline.loadModels(
                encoderDir: cohereDir, decoderDir: cohereDir, vocabDir: cohereDir)
            let pipeline = CoherePipeline()

            for (index, wav) in processedWavs.enumerated() {
                let id = wav.deletingPathExtension().lastPathComponent
                let (samples, _) = try loadUtterance(wav)
                let audio16k = decimateTo16k(samples)
                let start = Date()
                let result = try await pipeline.transcribe(audio: audio16k, models: models)
                let decodeMs = Int(Date().timeIntervalSince(start) * 1000)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                hypotheses.append(Hypothesis(id: id, text: text, decodeMs: decodeMs))
                log("[\(index + 1)/\(processedWavs.count)] \(id) \(decodeMs)ms \(text.prefix(60))")
            }

        default:
            fail("unknown engine \(engineName)")
        }
    } catch {
        runError = error
    }
    semaphore.signal()
}
semaphore.wait()

if let runError { fail("\(runError.localizedDescription)") }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try! encoder.encode(hypotheses).write(to: URL(fileURLWithPath: outPath))
print("wrote \(hypotheses.count) hypotheses to \(outPath)")
