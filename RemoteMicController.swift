//
//  RemoteMicController.swift
//  HyperVibe
//
//  Orchestrates activation + PacketLogger capture + Opus decode + selected
//  TranscriptionEngine (OpenAI / Parakeet).
//

import Foundation
import AppKit

/// End-to-end A2854 remote microphone path with zero extra hardware.
final class RemoteMicController {
    private let activator = MicActivator()
    private let capture: MicCapturePipeline
    private let decoder: OpusVoiceDecoder?
    private let polisher = TranscriptPolisher()
    private let recovery = DictationRecoveryStore()
    private let queue = DispatchQueue(label: "com.hypervibe.remote-mic")

    private var engine: TranscriptionEngine
    private(set) var engineID: TranscriptionEngineID

    private(set) var enabled: Bool
    private var siriHeld = false
    /// Accept HCI audio from press until a short post-release drain completes.
    /// Trailing Opus frames often arrive after the HID release.
    private var acceptingAudio = false
    private var finishWorkItem: DispatchWorkItem?
    /// Main-thread mirror of "a post-release drain is scheduled". Lets Siri-down
    /// skip `queue.sync` on the common idle path so the HUD can paint first.
    private var drainPending = false
    private var wavSamples = [Int16]()

    /// Wait this long after Siri-up for late HCI packets before finishing ASR.
    private static let postReleaseDrain: TimeInterval = 0.35
    /// After a cold capture start, wait up to this long for the first audio
    /// before giving up (helper bluetoothd restart alone takes ~2s).
    private static let coldStartGrace: TimeInterval = 3.0
    private var utteranceBeganAt: Date?
    private var captureWasColdAtPress = false
    private var utteranceReceivedFrame = false
    /// True from Siri-up until ASR (+ optional polish) finishes. Blocks stray
    /// `.ready` updates from the capture pipeline that would hide the spinner
    /// before text is typed.
    private var recognitionInFlight = false
    /// Bumped on every Siri-down / Siri-up / cancel so a deferred off-main rearm
    /// from an older press cannot stick PushToTalk after release.
    private let pressGenerationLock = NSLock()
    private var _pressGeneration = UUID()
    private var pressGeneration: UUID {
        get {
            pressGenerationLock.lock()
            defer { pressGenerationLock.unlock() }
            return _pressGeneration
        }
        set {
            pressGenerationLock.lock()
            _pressGeneration = newValue
            pressGenerationLock.unlock()
        }
    }
    private let armQueue = DispatchQueue(label: "com.hypervibe.mic-arm", qos: .userInitiated)
    /// Avoid re-arm spam (SetReport storms cut the remote mic stream after ~1s).
    private var lastRearmStatus: MicCaptureStatus?
    private var warmRetryAttempt = 0
    private var warmRetryWorkItem: DispatchWorkItem?
    private var lastAudioLevelPublishedAt: TimeInterval = 0

    var onStatus: ((MicCaptureStatus, String?) -> Void)?
    var onReadinessState: ((MicReadinessPresentationState) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onTranscribedText: ((String) -> Void)?
    var onEngineState: ((TranscriptionEngineID, TranscriptionEngineState) -> Void)?
    var onRecoveryModeChange: ((RecoveryMode) -> Void)?

    var recoveryMode: RecoveryMode { recovery.mode }

    var polishMode: TranscriptPolishMode {
        get { polisher.mode }
        set { polisher.mode = newValue }
    }

    var polishLocalSummary: String { polisher.localAvailabilitySummary }
    var polishCloudSummary: String { polisher.cloudAvailabilitySummary }

    func prewarmPolish() {
        polisher.prewarm()
    }

    func clearRecovery() {
        recovery.clear()
        publishRecoveryMode()
    }

    /// Smart recovery: retype last transcript, or resume interrupted PCM.
    func performRecovery() {
        switch recovery.mode {
        case .none:
            publishReadiness(.releasedBeforeReady)
        case .retype(let text):
            rmDebug("🎤 recovery retype len=\(text.count)")
            onTranscribedText?(text)
            recovery.clear()
            publishRecoveryMode()
        case .resume:
            resumePendingUtterance()
        }
    }

    private func publishRecoveryMode() {
        let mode = recovery.mode
        DispatchQueue.main.async { [weak self] in
            self?.onRecoveryModeChange?(mode)
        }
    }

    private func resumePendingUtterance() {
        guard enabled, !siriHeld, !recognitionInFlight else {
            rmDebug("🎤 recovery resume blocked (busy)")
            return
        }
        guard let pending = recovery.takePending() else {
            publishRecoveryMode()
            return
        }
        publishRecoveryMode()
        ensureCaptureWarm()
        guard engine.startUtterance() else {
            recovery.recordPending(pending.samples, sampleRate: pending.sampleRate, reason: .cancelled)
            publishRecoveryMode()
            return
        }
        // Splice separator so the decoder doesn't fuse words across the seam.
        let silenceCount = Int(pending.sampleRate * 0.15)
        let silence = [Int16](repeating: 0, count: max(0, silenceCount))
        if let parakeet = engine as? ParakeetTranscriptionEngine {
            parakeet.prepend(pcmS16: pending.samples + silence, sampleRate: pending.sampleRate)
        } else {
            engine.append(pcmS16: pending.samples + silence, sampleRate: pending.sampleRate)
        }
        siriHeld = true
        recognitionInFlight = false
        utteranceReceivedFrame = true
        captureWasColdAtPress = false
        utteranceBeganAt = Date()
        publishReadiness(.listening)
        queue.async {
            self.acceptingAudio = true
            self.wavSamples = pending.samples
        }
        // Time-boxed continuation: auto-finish after 15s unless Siri is pressed.
        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.siriHeld else { return }
            rmDebug("🎤 recovery resume auto-finish")
            _ = self.handleSiri(pressed: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: finish)
        // A physical Siri press during resume will take over via handleSiri.
        rmDebug("🎤 recovery resume samples=\(pending.samples.count)")
    }

    init() {
        // Start disabled: ensureDictation() enables once helper/PacketLogger/remote
        // readiness is verified off-main. Until then Siri presses fall through to
        // HID mapping instead of being consumed by a stack that can't capture.
        enabled = false
        engineID = TranscriptionEngineID.current
        engine = TranscriptionEngineFactory.make(engineID)
        capture = MicCapturePipeline()
        decoder = OpusVoiceDecoder()
        if decoder == nil {
            rmDebug("🎤 OpusVoiceDecoder unavailable")
        }
        capture.onStatus = { [weak self] status in
            guard let self else { return }
            self.onStatus?(status, nil)
            // After helper finishes bluetoothd restart, HID devices can reappear and
            // the earlier AF/PushToTalk poke is lost — re-arm once per phase while held.
            self.queue.async {
                switch status {
                case .listening, .streaming:
                    self.warmRetryAttempt = 0
                    self.warmRetryWorkItem?.cancel()
                    self.warmRetryWorkItem = nil
                    if (self.acceptingAudio || self.siriHeld), self.lastRearmStatus != status {
                        self.lastRearmStatus = status
                        let armID = self.pressGeneration
                        self.armQueue.async {
                            guard self.pressGeneration == armID else { return }
                            self.activator.rearmOnSiriDown()
                        }
                    }
                    if self.siriHeld {
                        self.publishReadiness(
                            self.utteranceReceivedFrame ? .listening : .readyToSpeak
                        )
                    } else if !self.recognitionInFlight {
                        self.publishReadiness(.ready)
                    }
                case .starting:
                    self.publishReadiness(.warming(showHUD: self.siriHeld))
                case .error(let message):
                    self.lastRearmStatus = nil
                    // Background warm-up failures (helper not installed yet during
                    // onboarding) must stay silent: `.error` pops the global HUD.
                    self.publishReadiness(self.siriHeld ? .error(message) : .unavailable)
                    self.scheduleWarmRetryLocked()
                case .missingTools(let detail):
                    self.lastRearmStatus = nil
                    self.publishReadiness(self.siriHeld ? .error(detail) : .unavailable)
                    self.scheduleWarmRetryLocked()
                case .idle:
                    self.lastRearmStatus = nil
                    self.publishReadiness(.unavailable)
                    self.scheduleWarmRetryLocked()
                }
            }
        }
        capture.onPayload = { [weak self] payload in
            self?.handlePayload(payload)
        }
        bindEngineCallbacks()
    }

    var engineState: TranscriptionEngineState { engine.state }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: RemoteMicLab.enabledDefaultsKey)
        if on {
            engine.prepare(completion: nil)
            startIdleCaptureIfEnabled()
        } else {
            queue.async {
                self.warmRetryWorkItem?.cancel()
                self.warmRetryWorkItem = nil
            }
            stopSession(cancelRecognition: true)
            capture.stop()
            activator.disarm()
        }
        publishStatus()
    }

    func setEngine(_ id: TranscriptionEngineID) {
        guard id != engineID else { return }
        let old = engine
        old.onState = nil
        old.cancel()
        engineID = id
        TranscriptionEngineID.current = id
        engine = TranscriptionEngineFactory.make(id)
        bindEngineCallbacks()
        if enabled {
            engine.prepare(completion: nil)
        }
        publishStatus()
        onEngineState?(engineID, engine.state)
    }

    func prepareSelectedEngine(completion: ((Bool) -> Void)? = nil) {
        engine.prepare(completion: completion)
    }

    func startParakeetDownload(completion: ((Bool) -> Void)? = nil) {
        guard let parakeet = engine as? ParakeetTranscriptionEngine else {
            setEngine(.parakeet)
            (engine as? ParakeetTranscriptionEngine)?.startModelDownload(completion: completion)
            return
        }
        parakeet.startModelDownload(completion: completion)
    }

    func cancelParakeetDownload() {
        (engine as? ParakeetTranscriptionEngine)?.cancelModelDownload()
    }

    /// Prepare the selected engine and keep HCI capture warm so the first Siri
    /// press after idle isn't racing PacketLogger/bluetoothd startup (~2s).
    func startIdleCaptureIfEnabled() {
        guard enabled else {
            publishStatus()
            return
        }
        engine.prepare(completion: nil)
        ensureCaptureWarm()
    }

    /// Idempotent lifecycle hook for remote connect, wake, and button activity.
    func ensureCaptureWarm() {
        guard enabled else { return }
        // `capture.start()` performs helper readiness checks on its own serial queue.
        // Avoid synchronous helper IPC on the main thread.
        switch capture.status {
        case .idle, .error, .missingTools:
            publishReadiness(.warming(showHUD: false))
            capture.start()
        case .starting:
            publishReadiness(.warming(showHUD: false))
        case .listening, .streaming:
            publishReadiness(.ready)
        }
        publishStatus()
    }

    func attachSeizedDevices(_ devices: [IOHIDDevice]) {
        guard enabled, !devices.isEmpty else { return }
        activator.useSharedDevices(devices)
        queue.async { [weak self] in
            guard let self, self.acceptingAudio || self.siriHeld else { return }
            let armID = self.pressGeneration
            self.armQueue.async {
                guard self.pressGeneration == armID else { return }
                self.activator.rearmOnSiriDown()
            }
        }
    }

    func shutdown() {
        stopSession(cancelRecognition: true)
        capture.stop()
        activator.disarm()
        clearRecovery()
    }

    /// AGENTS.md invariant: push-to-talk must end when the remote disconnects.
    /// Without this, a Siri press with no matching key-up sticks forever —
    /// handleSiri swallows all later presses while `siriHeld` is true.
    func remoteDidDisconnect() {
        guard siriHeld else { return }
        rmDebug("🎤 remote disconnected while Siri held — forcing release")
        let snapshot = queue.sync { wavSamples }
        if !snapshot.isEmpty {
            recovery.recordPending(snapshot, reason: .disconnected)
            publishRecoveryMode()
        }
        handleSiri(pressed: false)
    }

    @discardableResult
    func handleSiri(pressed: Bool) -> Bool {
        guard enabled else { return false }
        if pressed {
            guard !siriHeld else { return true }
            switch capture.status {
            case .error, .missingTools:
                // Capture stack is broken (helper died, PacketLogger missing):
                // don't swallow the button. Fall through to HID mapping and kick
                // a warm-up retry so a recovered stack serves the next press.
                // .idle stays consumed — that's the normal cold-start path.
                rmDebug("🎤 Siri down — capture \(capture.status), falling through")
                ensureCaptureWarm()
                return false
            case .idle, .starting, .listening, .streaming:
                break
            }
            siriHeld = true
            lastRearmStatus = nil
            utteranceReceivedFrame = false
            // A new press supersedes any in-flight polish from the previous utterance.
            polisher.cancel()
            recognitionInFlight = false
            let coldStart: Bool
            switch capture.status {
            case .idle, .error, .missingTools, .starting:
                coldStart = true
            default:
                coldStart = false
            }
            captureWasColdAtPress = coldStart
            utteranceBeganAt = Date()
            // Paint the wave before any HID / capture work. publishReadiness does a
            // synchronous display + CATransaction.flush, so the frame is committed to
            // the window server before we leave this callback. Utterance lifecycle
            // stays sync here; only the blocking IOHID rearm is deferred off-main so
            // the breathing timer can keep ticking (and a keep-alive wave is already
            // mid-phase under alpha 0).
            publishReadiness(.readyToSpeak)

            // Commit any still-draining prior utterance before startUtterance clears PCM.
            if drainPending {
                queue.sync {
                    if let work = self.finishWorkItem {
                        work.cancel()
                        self.finishWorkItem = nil
                    }
                    if self.acceptingAudio {
                        self.commitUtteranceLocked()
                    }
                }
                drainPending = false
            }

            guard engine.startUtterance() else {
                siriHeld = false
                queue.async { self.acceptingAudio = false }
                if case .needsSetup(let reason) = engine.state {
                    presentEngineSetupAlert(reason)
                }
                rmDebug("🎤 Siri down — engine not ready (\(engineID.rawValue))")
                publishReadiness(.ready)
                publishStatus()
                // Not consumed: let the press fall through to HID mapping so a
                // failed dictation stack doesn't hijack the Siri button.
                return false
            }
            decoder?.reset()
            queue.async {
                self.acceptingAudio = true
                self.wavSamples.removeAll(keepingCapacity: true)
            }

            let armID = UUID()
            pressGeneration = armID
            let needsCaptureStart: Bool
            switch capture.status {
            case .idle, .error, .missingTools:
                needsCaptureStart = true
            default:
                needsCaptureStart = false
            }
            // Arm synchronously on the press callback. Deferring it let a fast
            // release bump `pressGeneration` first, so the queued arm dropped
            // itself and the tap captured no audio. The SetReport is cheap thanks
            // to proven-target caching, and the HUD frame is already committed
            // above via publishReadiness's display + CATransaction.flush.
            activator.rearmOnSiriDown()
            if needsCaptureStart {
                armQueue.async { [weak self] in
                    guard let self, self.pressGeneration == armID else { return }
                    self.capture.start()
                }
            }
            rmDebug("🎤 Siri down — mic armed engine=\(engineID.rawValue) coldStart=\(coldStart)")
        } else if siriHeld {
            siriHeld = false
            // Invalidate any in-flight off-main rearm from this press.
            pressGeneration = UUID()
            recognitionInFlight = true
            if captureWasColdAtPress && !utteranceReceivedFrame {
                switch capture.status {
                case .idle, .starting, .missingTools, .error:
                    recognitionInFlight = false
                    publishReadiness(.releasedBeforeReady)
                default:
                    publishReadiness(.recognizing)
                }
            } else {
                publishReadiness(.recognizing)
            }
            // Keep PushToTalk armed during drain so trailing HCI frames still arrive.
            let drain: TimeInterval
            if captureWasColdAtPress {
                let elapsed = utteranceBeganAt.map { Date().timeIntervalSince($0) } ?? 0
                drain = max(Self.postReleaseDrain, Self.coldStartGrace - elapsed)
            } else {
                drain = Self.postReleaseDrain
            }
            rmDebug(String(format: "🎤 Siri up — draining %.2fs frames=%d cold=%@",
                           drain, capture.framesSeen, captureWasColdAtPress ? "yes" : "no"))
            let work = DispatchWorkItem { [weak self] in
                self?.finishHeldUtterance()
            }
            drainPending = true
            queue.sync {
                self.finishWorkItem = work
            }
            queue.asyncAfter(deadline: .now() + drain, execute: work)
        } else {
            // Release without a hold we own (press fell through above) — pass it
            // through as well so HID mapping sees a paired key-down/key-up.
            publishStatus()
            return false
        }
        publishStatus()
        return true
    }

    private func finishHeldUtterance() {
        // Runs on `queue`.
        finishWorkItem = nil
        DispatchQueue.main.async {
            self.drainPending = false
            self.activator.disarm()
        }
        commitUtteranceLocked()
    }

    /// Snapshots engine PCM immediately (finishUtterance's first action is sync).
    /// Must be called before a subsequent startUtterance.
    private func commitUtteranceLocked() {
        acceptingAudio = false
        let debugSamples = wavSamples
        wavSamples.removeAll(keepingCapacity: true)
        rmDebug("🎤 recognition finishing frames=\(capture.framesSeen) debugSamples=\(debugSamples.count)")
        let engineRef = engine
        // Snapshot happens synchronously inside finishUtterance before any await.
        engineRef.finishUtterance { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                if let text, !text.isEmpty {
                    // Keep the recognizing HUD up through polish; type once at the end.
                    self.publishReadiness(.recognizing)
                    self.polisher.polish(text) { [weak self] polished in
                        guard let self else { return }
                        self.recognitionInFlight = false
                        rmDebug("🎤 typed transcript len=\(polished.count)")
                        self.recovery.recordTranscript(polished)
                        self.publishRecoveryMode()
                        self.onTranscribedText?(polished)
                        self.publishReadiness(.ready)
                        self.publishStatus()
                    }
                } else {
                    rmDebug("🎤 transcript empty — no typing")
                    if !debugSamples.isEmpty {
                        self.recovery.recordPending(debugSamples, reason: .emptyResult)
                        self.publishRecoveryMode()
                    }
                    self.recognitionInFlight = false
                    self.publishReadiness(.ready)
                    self.publishStatus()
                }
                return
            case .failure(let error):
                self.recognitionInFlight = false
                if let te = error as? TranscriptionEngineError, case .emptyAudio = te {
                    rmDebug("🎤 empty utterance ignored")
                    self.publishReadiness(.ready)
                } else {
                    if !debugSamples.isEmpty {
                        self.recovery.recordPending(debugSamples, reason: .engineError)
                        self.publishRecoveryMode()
                    }
                    self.publishReadiness(.error(error.localizedDescription))
                    self.presentTranscriptionFailure(error)
                }
            }
            self.publishStatus()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.decoder?.reset()
            if !debugSamples.isEmpty {
                self.writeDebugWAV(samples: debugSamples)
            }
            self.publishStatus()
        }
    }

    private func bindEngineCallbacks() {
        let boundID = engineID
        engine.onState = { [weak self] state in
            guard let self, self.engineID == boundID else { return }
            self.onEngineState?(boundID, state)
            self.publishStatus()
        }
    }

    private func handlePayload(_ payload: Data) {
        queue.async {
            guard self.acceptingAudio else { return }
            guard let decoder = self.decoder else { return }
            let pcm = decoder.feed(payload)
            guard !pcm.isEmpty else { return }
            if !self.utteranceReceivedFrame {
                self.utteranceReceivedFrame = true
                let latency = self.utteranceBeganAt.map { Date().timeIntervalSince($0) } ?? 0
                rmDebug(String(
                    format: "🎤 utterance first frame latency=%.3fs cold=%@",
                    latency,
                    self.captureWasColdAtPress ? "yes" : "no"
                ))
                self.publishReadiness(.listening)
            }
            let now = Date.timeIntervalSinceReferenceDate
            if now - self.lastAudioLevelPublishedAt >= 1.0 / 30.0 {
                self.lastAudioLevelPublishedAt = now
                var sumSquares = 0.0
                var count = 0
                for index in stride(from: 0, to: pcm.count, by: 8) {
                    let value = Double(pcm[index]) / 32768.0
                    sumSquares += value * value
                    count += 1
                }
                if count > 0 {
                    let rms = sqrt(sumSquares / Double(count))
                    let normalized = Float(min(1, max(0, (rms - 0.003) * 18)))
                    self.onAudioLevel?(normalized)
                }
            }
            self.engine.append(pcmS16: pcm, sampleRate: Double(OpusVoiceDecoder.sampleRate))
            if self.wavSamples.count < 48_000 * 30 {
                self.wavSamples.append(contentsOf: pcm)
            }
        }
    }

    private func stopSession(cancelRecognition: Bool) {
        queue.sync {
            self.finishWorkItem?.cancel()
            self.finishWorkItem = nil
            self.warmRetryWorkItem?.cancel()
            self.warmRetryWorkItem = nil
            self.acceptingAudio = false
            self.siriHeld = false
        }
        drainPending = false
        polisher.cancel()
        recognitionInFlight = false
        pressGeneration = UUID()
        activator.disarm()
        if cancelRecognition {
            engine.cancel()
        } else {
            recognitionInFlight = true
            publishReadiness(.recognizing)
            engine.finishUtterance { [weak self] result in
                if case .success(let text) = result, let text, !text.isEmpty {
                    self?.polisher.polish(text) { polished in
                        self?.recognitionInFlight = false
                        self?.onTranscribedText?(polished)
                        self?.publishReadiness(.ready)
                        self?.publishStatus()
                    }
                    return
                }
                self?.recognitionInFlight = false
                self?.publishReadiness(.ready)
                self?.publishStatus()
            }
        }
        decoder?.reset()
    }

    private func publishStatus() {
        onStatus?(enabled ? capture.status : .idle, nil)
    }

    private func publishReadiness(_ state: MicReadinessPresentationState) {
        let deliver = { [weak self] in
            guard let self else { return }
            // `.ready` is decided on the capture queue, so one computed just before a
            // Siri press can arrive after the press already raised the HUD. Honouring it
            // then would tear the waveform down mid-utterance. The same applies while
            // ASR/polish is still running after Siri-up — keep the spinner visible.
            if state == .ready, self.siriHeld || self.recognitionInFlight { return }
            self.onReadinessState?(state)
        }
        // HID callbacks already run on the main runloop — deliver inline so the wave
        // paints in the same turn as the Siri press instead of waiting a frame.
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private func scheduleWarmRetryLocked() {
        guard enabled, warmRetryWorkItem == nil else { return }
        warmRetryAttempt = min(warmRetryAttempt + 1, 5)
        let delay = min(pow(2.0, Double(warmRetryAttempt - 1)), 16.0)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.warmRetryWorkItem = nil
            }
            self.startIdleCaptureIfEnabled()
        }
        warmRetryWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        rmDebug(String(format: "🎤 warm capture retry in %.1fs", delay))
    }

    private func presentEngineSetupAlert(_ reason: String) {
        DispatchQueue.main.async {
            let alert = NSAlert.hyperVibeAlert()
            alert.messageText = "听写引擎未就绪"
            alert.informativeText = "\(self.engineID.displayName)：\(reason)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runHyperVibeModal()
        }
    }

    private func presentTranscriptionFailure(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert.hyperVibeAlert()
            alert.messageText = "\(self.engineID.displayName) 转写失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runHyperVibeModal()
        }
    }

    private func writeDebugWAV(samples: [Int16]) {
        let url = URL(fileURLWithPath: "/tmp/hypervibe-remote-mic.wav")
        do {
            try PCMWaveWriter.write(
                samples: samples,
                sampleRate: Int(OpusVoiceDecoder.sampleRate),
                to: url
            )
            rmDebug("🎤 wrote debug WAV \(url.path) samples=\(samples.count)")
        } catch {
            rmDebug("🎤 WAV write failed: \(error)")
        }
    }
}
