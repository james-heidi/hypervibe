//
//  ParakeetTranscriptionEngine.swift
//  HyperVibe
//
//  Local NVIDIA Parakeet via FluidAudio. Models download only when the user
//  selects this engine — never during DMG packaging.
//

import AVFAudio
import Foundation
import FluidAudio

final class ParakeetTranscriptionEngine: TranscriptionEngine {
    let id: TranscriptionEngineID = .parakeet
    var displayName: String { id.displayName }
    private(set) var state: TranscriptionEngineState = .idle
    var onState: ((TranscriptionEngineState) -> Void)?

    private let queue = DispatchQueue(label: "com.hypervibe.parakeet-transcription")
    private let modelVersion: AsrModelVersion = .v3

    /// Mirrored by tools/stt-eval/ParakeetEvalCLI (keep configs in sync).
    /// Accuracy-tuned config for the v3 multilingual model (per FluidAudio guidance):
    /// `melChunkContext=false` avoids the English-biased decoder drift the 80ms prepend
    /// causes on multilingual audio, and `dualDecodeArbitration=true` probes the opening
    /// chunk with multiple strategies and commits to the highest-confidence one.
    private static let asrConfig = ASRConfig(
        melChunkContext: false,
        dualDecodeArbitration: true
    )
    private var samples = [Int16]()
    private var sampleRate: Double = 48_000
    private var generation = UUID()
    private var asrManager: AsrManager?
    private var recognitionTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var cancelDownload = false
    private let progressThrottle = ModelProgressThrottle()
    /// `ModelHub.download` splits its own operation into download + compile and hands
    /// the handler only the download half, so its fraction tops out here.
    private static let hubDownloadPhaseWeight = 0.5

    private func isCancelRequested() -> Bool { cancelDownload }

    static var modelsCached: Bool {
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        return AsrModels.modelsExist(at: dir, version: .v3)
    }

    // MARK: - Vocabulary boosting (CTC keyword spotting, opt-in)

    private var ctcSpotter: CtcKeywordSpotter?
    private var vocabRescorer: VocabularyRescorer?
    private var vocabContext: CustomVocabularyContext?
    /// Rebuild the rescorer only when the user's term list actually changed.
    private var vocabFingerprint: String?

    static var ctcModelsCached: Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory())
    }

    /// One-time CTC model fetch (menu-triggered, like the main model).
    func startCtcModelDownload(completion: ((Bool) -> Void)? = nil) {
        publish(.preparing(ModelPrepProgress(
            phase: .listing, fraction: 0.05, bytesPerSecond: nil, etaSeconds: nil)))
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await CtcModels.downloadAndLoad()
                self.prewarmVocabularyBoost()
                self.publish(Self.modelsCached ? .ready : .needsSetup("需下载模型"))
                DispatchQueue.main.async { completion?(true) }
            } catch {
                rmDebug("📖 CTC model download failed: \(error.localizedDescription)")
                self.publish(Self.modelsCached ? .ready : .needsSetup("需下载模型"))
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    /// Load/refresh the CTC spotter + rescorer. First load compiles CoreML
    /// (seconds) — call from prewarm, never let dictation wait more than the
    /// per-utterance budget for it.
    private func ensureVocabStackLoaded() async throws {
        guard !VocabularyStore.shared.terms().isEmpty else { return }
        let fingerprint = VocabularyStore.shared.fingerprint
        if vocabRescorer != nil && vocabFingerprint == fingerprint { return }
        // loadWithCtcTokens tokenizes each term for the CTC head —
        // terms without ctcTokenIds are never spotted.
        let (context, models) = try await CustomVocabularyContext.loadWithCtcTokens(
            from: VocabularyStore.fileURL.path)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        // spotterRescueEnabled=false: the acoustic rescue pass over-fires
        // on our quiet remote audio ("Today"→"Parakeet"); alias/similarity
        // replacement alone is precise (FluidAudio #724 control).
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false))
        queue.sync {
            ctcSpotter = spotter
            vocabContext = context
            vocabRescorer = rescorer
            vocabFingerprint = fingerprint
        }
    }

    /// Warm the boost stack off the dictation path (toggle-on / app start).
    func prewarmVocabularyBoost() {
        guard VocabularyStore.shared.isEnabled, Self.ctcModelsCached else { return }
        Task { [weak self] in
            let start = Date()
            do {
                try await self?.ensureVocabStackLoaded()
                rmDebug(String(format: "📖 vocabulary stack warm in %.1fs", Date().timeIntervalSince(start)))
            } catch {
                rmDebug("📖 vocabulary prewarm failed: \(error.localizedDescription)")
            }
        }
    }

    /// Boost `text` toward the user's vocabulary. Fails open: any error or
    /// missing precondition returns the unboosted transcript. If the stack is
    /// still cold (prewarm not finished), skip — never stall dictation.
    private func applyVocabularyBoost(
        text: String,
        tokenTimings: [TokenTiming]?,
        audio48k: [Int16]
    ) async -> String {
        guard VocabularyStore.shared.isEnabled, Self.ctcModelsCached,
              let tokenTimings, !tokenTimings.isEmpty else { return text }
        do {
            if vocabRescorer == nil || vocabFingerprint != VocabularyStore.shared.fingerprint {
                // Cold or stale: kick a background (re)load and type unboosted now.
                prewarmVocabularyBoost()
                rmDebug("📖 vocabulary stack cold — this utterance unboosted")
                return text
            }
            guard let spotter = ctcSpotter, let rescorer = vocabRescorer,
                  let context = vocabContext else { return text }

            // 48 kHz Int16 → 16 kHz Float via FluidAudio's resampler.
            let f = audio48k.map { Float($0) / 32768.0 }
            let audio16k = try AudioConverter().resample(f, from: 48_000)
            let spot = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: audio16k, customVocabulary: context, minScore: nil)
            guard !spot.logProbs.isEmpty else { return text }
            // Pass vocab-size tuned cbw and the file's minSimilarity — the
            // rescorer does NOT read them from the context on its own.
            let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
            let out = rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: sizeConfig.cbw,
                minSimilarity: max(sizeConfig.minSimilarity, context.minSimilarity))
            if out.wasModified {
                let applied = out.replacements.filter { $0.shouldReplace }
                    .map { "\($0.originalWord)→\($0.replacementWord ?? "")" }
                rmDebug("📖 vocabulary boost applied: \(applied.joined(separator: ", "))")
                return out.text
            }
            return text
        } catch {
            rmDebug("📖 vocabulary boost failed (using unboosted): \(error.localizedDescription)")
            return text
        }
    }

    func prepare(completion: ((Bool) -> Void)?) {
        prewarmVocabularyBoost()
        if Self.modelsCached {
            ensureManagerLoaded { [weak self] ok in
                if ok {
                    self?.publish(.ready)
                } else {
                    self?.publish(.unavailable("Parakeet 模型加载失败"))
                }
                completion?(ok)
            }
        } else {
            publish(.needsSetup("需下载模型"))
            completion?(false)
        }
    }

    /// Download bytes once, then compile once — avoids FluidAudio's downloadAndLoad
    /// double-compile and the stuck-at-100% progress symptom.
    func startModelDownload(completion: ((Bool) -> Void)? = nil) {
        if Self.modelsCached {
            prepare(completion: completion)
            return
        }
        cancelDownload = false
        progressThrottle.reset()
        ModelDownloadMirror.applyToRegistry()
        publish(.preparing(ModelPrepProgress(
            phase: .listing,
            fraction: 0.01,
            bytesPerSecond: nil,
            etaSeconds: nil
        )))
        downloadTask?.cancel()
        let startedAt = Date()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cacheDir = AsrModels.defaultCacheDirectory(for: self.modelVersion)
                let parentDir = cacheDir.deletingLastPathComponent()

                // Phase 1 — bytes only (ModelHub.download compiles nothing).
                try await ModelHub.download(
                    .parakeetV3,
                    to: parentDir,
                    variant: ParakeetEncoderPrecision.int8.rawValue
                ) { [weak self] progress in
                    guard let self, !self.isCancelRequested() else { return }
                    var files = 0
                    var total = 0
                    if case .downloading(let completed, let count) = progress.phase {
                        files = completed
                        total = count
                    }
                    let mapped = ModelPrepProgress.fromDownloadFraction(
                        progress.fractionCompleted,
                        phaseWeight: Self.hubDownloadPhaseWeight,
                        filesCompleted: files,
                        filesTotal: total,
                        etaSeconds: ModelPrepProgress.estimateETA(
                            fraction: progress.fractionCompleted / Self.hubDownloadPhaseWeight,
                            elapsed: Date().timeIntervalSince(startedAt)
                        )
                    )
                    if self.progressThrottle.shouldPublish(mapped) {
                        self.publish(.preparing(mapped))
                    }
                }
                try Task.checkCancellation()
                if self.isCancelRequested() {
                    self.publish(.preparing(.paused))
                    DispatchQueue.main.async { completion?(false) }
                    return
                }

                guard AsrModels.modelsExist(at: cacheDir, version: self.modelVersion) else {
                    throw TranscriptionEngineError.backend("模型文件不完整")
                }

                // Phase 2 — compile once.
                self.publish(.preparing(ModelPrepProgress.compiling(name: "CoreML", step: 1, total: 2)))
                let models = try await AsrModels.load(
                    from: cacheDir,
                    version: self.modelVersion,
                    progressHandler: { [weak self] progress in
                        guard let self else { return }
                        let mapped = ModelPrepProgress(
                            phase: .compiling("CoreML"),
                            fraction: 0.85 + 0.12 * progress.fractionCompleted,
                            bytesPerSecond: nil,
                            etaSeconds: nil
                        )
                        if self.progressThrottle.shouldPublish(mapped) {
                            self.publish(.preparing(mapped))
                        }
                    }
                )
                try Task.checkCancellation()
                self.publish(.preparing(.warmup))
                let manager = AsrManager(config: Self.asrConfig)
                try await manager.loadModels(models)
                self.queue.sync { self.asrManager = manager }
                self.publish(.ready)
                DispatchQueue.main.async { completion?(true) }
            } catch is CancellationError {
                self.publish(.preparing(.paused))
                DispatchQueue.main.async { completion?(false) }
            } catch {
                if !self.isCancelRequested() {
                    self.publish(.unavailable("下载失败: \(error.localizedDescription)"))
                } else {
                    self.publish(.preparing(.paused))
                }
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    func cancelModelDownload() {
        cancelDownload = true
        downloadTask?.cancel()
        downloadTask = nil
        if Self.modelsCached {
            publish(.ready)
        } else {
            publish(.preparing(.paused))
        }
    }

    @discardableResult
    func startUtterance() -> Bool {
        guard Self.modelsCached || asrManager != nil else {
            publish(.needsSetup("需下载模型"))
            return false
        }
        generation = UUID()
        queue.async { [weak self] in
            self?.samples.removeAll(keepingCapacity: true)
        }
        publish(.listening)
        return true
    }

    /// Seed the utterance buffer before live frames (recovery resume path).
    func prepend(pcmS16 samples: [Int16], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.sampleRate = sampleRate
            var merged = samples
            merged.append(contentsOf: self.samples)
            let cap = Int(sampleRate) * 60
            if merged.count > cap {
                self.samples = Array(merged.suffix(cap))
            } else {
                self.samples = merged
            }
        }
    }

    func append(pcmS16 samples: [Int16], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.sampleRate = sampleRate
            if self.samples.count < Int(sampleRate) * 60 {
                self.samples.append(contentsOf: samples)
            }
        }
    }

    func finishUtterance(completion: @escaping (Result<String?, Error>) -> Void) {
        publish(.recognizing)
        let opID = generation
        let (pcm, rate): ([Int16], Int) = queue.sync {
            let captured = samples
            samples.removeAll(keepingCapacity: true)
            return (captured, Int(sampleRate))
        }
        guard pcm.count >= 12_000 else {
            publish(.ready)
            rmDebug("🎤 Parakeet skip short clip samples=\(pcm.count)")
            CorpusRecorder.shared.recordDropped(pcmS16: pcm, sampleRate: rate, engineID: id.rawValue)
            DispatchQueue.main.async { completion(.success(nil)) }
            return
        }

        // In-memory decode: no temp-WAV round-trip. FluidAudio's buffer overload
        // uses the same audioConverter as the URL path, so transcripts match.
        let frontEndMode = AudioFrontEndMode.current
        let boosted = AudioFrontEnd.process(pcm, sampleRate: rate, mode: frontEndMode)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(boosted.count)) else {
            publish(.ready)
            DispatchQueue.main.async {
                completion(.failure(TranscriptionEngineError.backend("audio buffer allocation failed")))
            }
            return
        }
        buffer.frameLength = AVAudioFrameCount(boosted.count)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<boosted.count {
                channel[i] = Float(boosted[i]) / 32768.0
            }
        }

        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureManagerLoadedAsync()
                try Task.checkCancellation()
                guard self.generation == opID else {
                    DispatchQueue.main.async { completion(.success(nil)) }
                    return
                }
                let manager = self.queue.sync { () -> AsrManager? in self.asrManager }
                guard let manager else {
                    throw TranscriptionEngineError.backend("Parakeet manager unavailable")
                }
                var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
                let decodeStart = Date()
                let result = try await manager.transcribe(buffer, decoderState: &decoderState)
                let decodeMs = Int(Date().timeIntervalSince(decodeStart) * 1000)
                try Task.checkCancellation()
                guard self.generation == opID else {
                    DispatchQueue.main.async { completion(.success(nil)) }
                    return
                }
                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    text = await self.applyVocabularyBoost(
                        text: text, tokenTimings: result.tokenTimings, audio48k: boosted)
                }
                CorpusRecorder.shared.record(
                    pcmS16: boosted,
                    rawPCM: pcm,
                    sampleRate: rate,
                    engineID: self.id.rawValue,
                    decodeMs: decodeMs,
                    rawTranscript: text,
                    frontEndMode: frontEndMode.rawValue
                )
                self.publish(.ready)
                rmDebug("🎤 Parakeet result samples=\(pcm.count) text=\(text.isEmpty ? "<empty>" : text)")
                DispatchQueue.main.async {
                    completion(.success(text.isEmpty ? nil : text))
                }
            } catch is CancellationError {
                DispatchQueue.main.async { completion(.success(nil)) }
            } catch {
                guard self.generation == opID else {
                    DispatchQueue.main.async { completion(.success(nil)) }
                    return
                }
                self.publish(.ready)
                rmDebug("🎤 Parakeet error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(TranscriptionEngineError.backend(error.localizedDescription)))
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        queue.async { [weak self] in
            self?.samples.removeAll(keepingCapacity: true)
        }
        if case .downloading = state {
            // keep downloading
        } else if case .preparing = state {
            // keep downloading / paused state
        } else if Self.modelsCached {
            publish(.ready)
        } else {
            publish(.needsSetup("需下载模型"))
        }
    }

    private func ensureManagerLoaded(completion: @escaping (Bool) -> Void) {
        Task {
            do {
                try await ensureManagerLoadedAsync()
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private func ensureManagerLoadedAsync() async throws {
        let existing: AsrManager? = queue.sync { asrManager }
        if let existing, await existing.isAvailable { return }
        let models = try await AsrModels.load(
            from: AsrModels.defaultCacheDirectory(for: modelVersion),
            version: modelVersion
        )
        let manager = AsrManager(config: Self.asrConfig)
        try await manager.loadModels(models)
        queue.sync { asrManager = manager }
    }

    private func publish(_ state: TranscriptionEngineState) {
        self.state = state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onState?(state)
        }
    }
}
