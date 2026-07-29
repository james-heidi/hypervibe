//
//  ParakeetTranscriptionEngine.swift
//  HyperVibe
//
//  Local NVIDIA Parakeet via FluidAudio. Models download only when the user
//  selects this engine — never during DMG packaging.
//

import Foundation
import FluidAudio

final class ParakeetTranscriptionEngine: TranscriptionEngine {
    let id: TranscriptionEngineID = .parakeet
    var displayName: String { id.displayName }
    private(set) var state: TranscriptionEngineState = .idle
    var onState: ((TranscriptionEngineState) -> Void)?

    private let queue = DispatchQueue(label: "com.hypervibe.parakeet-transcription")
    private let modelVersion: AsrModelVersion = .v3

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

    func prepare(completion: ((Bool) -> Void)?) {
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
            DispatchQueue.main.async { completion(.success(nil)) }
            return
        }

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypervibe-parakeet-\(UUID().uuidString).wav")
        do {
            let boosted = PCMWaveWriter.boostForASR(pcm)
            try PCMWaveWriter.write(samples: boosted, sampleRate: rate, to: wav)
        } catch {
            publish(.ready)
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: wav) }
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
                let result = try await manager.transcribe(wav, decoderState: &decoderState)
                try Task.checkCancellation()
                guard self.generation == opID else {
                    DispatchQueue.main.async { completion(.success(nil)) }
                    return
                }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
