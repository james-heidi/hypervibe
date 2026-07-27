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
    private var samples = [Int16]()
    private var sampleRate: Double = 48_000
    private var generation = UUID()
    private var asrManager: AsrManager?
    private var recognitionTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var cancelDownload = false
    private var lastPublishedPercent = -1

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

    /// Start HuggingFace download when the user picks Parakeet from the menu.
    func startModelDownload(completion: ((Bool) -> Void)? = nil) {
        if Self.modelsCached {
            prepare(completion: completion)
            return
        }
        cancelDownload = false
        lastPublishedPercent = -1
        publish(.downloading(0))
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await AsrModels.downloadAndLoad(
                    version: self.modelVersion,
                    progressHandler: { [weak self] progress in
                        guard let self, !self.cancelDownload else { return }
                        // Throttle UI updates to whole-percent steps to avoid menu thrash.
                        let percent = Int((progress.fractionCompleted * 100).rounded(.down))
                        guard percent > self.lastPublishedPercent else { return }
                        self.lastPublishedPercent = percent
                        self.publish(.downloading(Double(percent) / 100.0))
                    }
                )
                if Task.isCancelled || self.cancelDownload {
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                self.queue.sync { self.asrManager = manager }
                self.publish(.ready)
                DispatchQueue.main.async { completion?(true) }
            } catch {
                if !self.cancelDownload {
                    self.publish(.unavailable("下载失败: \(error.localizedDescription)"))
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
            publish(.needsSetup("需下载模型"))
        }
    }

    @discardableResult
    func startUtterance() -> Bool {
        // Manager availability is actor-isolated; cache presence is enough to start
        // buffering PCM. finishUtterance loads/awaits the manager.
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
        // Snapshot synchronously so a subsequent startUtterance cannot clear the buffer
        // out from under an in-flight finish.
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
            // keep downloading; utterance cancel is independent
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
        let manager = AsrManager(config: .default)
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
