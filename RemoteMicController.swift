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

    /// Hard cap after Siri-up for late HCI packets before finishing ASR.
    private static let postReleaseDrain: TimeInterval = 0.35
    /// After a cold capture start, wait up to this long for the first audio
    /// before giving up (helper bluetoothd restart alone takes ~2s).
    private static let coldStartGrace: TimeInterval = 3.0
    /// Adaptive drain: commit once no voice frame arrived for this long
    /// (frames are 20 ms; HCI batching observed ≲60 ms). Caps above still hold.
    private static let quietWindow: TimeInterval = 0.12
    private static let drainPollInterval: TimeInterval = 0.05
    /// Stamped on `queue` for every decoded voice frame (adaptive drain input).
    private var lastVoiceFrameAt: Date?
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
    /// Loudest per-frame level since the last publish (see handlePayload). Accessed on `queue`.
    private var pendingAudioLevelPeak: Float = 0

    var onStatus: ((MicCaptureStatus, String?) -> Void)?
    var onReadinessState: ((MicReadinessPresentationState) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onTranscribedText: ((String) -> Void)?
    /// Polish correction: (rawAsTyped, polished). Fired only when guards pass.
    var onReplaceTranscribedText: ((String, String) -> Void)?

    /// Apply polish results as a typed correction after the raw transcript.
    static var correctionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "dictationCorrectionEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dictationCorrectionEnabled") }
    }
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
        lastRearmStatus = nil
        publishReadiness(.listening)
        queue.async {
            self.acceptingAudio = true
            self.wavSamples = pending.samples
        }
        // Finishing the previous utterance disarmed PushToTalk, and a capture that
        // is already warm emits no new status, so `onStatus` will not re-arm either.
        // Without this the continuation window below records silence and only the
        // buffered PCM reaches the engine.
        pressGeneration = UUID()
        activator.rearmOnSiriDown()
        // Time-boxed continuation: auto-finish after 15s unless Siri is pressed.
        let finish = DispatchWorkItem { [weak self] in
            guard let self, self.siriHeld else { return }
            rmDebug("🎤 recovery resume auto-finish")
            _ = self.handleSiri(pressed: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: finish)
        // Resume already counts as held, so a physical Siri press is swallowed by
        // `handleSiri`; its release is what closes the utterance early.
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

    func prewarmVocabularyBoost() {
        (engine as? ParakeetTranscriptionEngine)?.prewarmVocabularyBoost()
    }

    func startCtcModelDownload() {
        guard let parakeet = engine as? ParakeetTranscriptionEngine else {
            setEngine(.parakeet)
            (engine as? ParakeetTranscriptionEngine)?.startCtcModelDownload()
            return
        }
        parakeet.startCtcModelDownload()
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
        // Blocking variant: the activator is asynchronous now, and quitting before
        // PushToTalk(false) lands would leave the remote's microphone armed.
        activator.disarmAndWait()
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
            queue.async { self.lastVoiceFrameAt = nil }
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
            DictationTiming.markPress()
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
                // Clear the throttle so the first frame of this press publishes its
                // level at once instead of waiting out a window from the last utterance.
                self.lastAudioLevelPublishedAt = 0
                self.pendingAudioLevelPeak = 0
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
            // Arm from the press callback, but do not wait for it: MicActivator
            // serializes internally, so this returns at once and the ~1.2 s of
            // SetReport round trips no longer freeze the main runloop (and with it
            // the dictation wave) for the whole press.
            //
            // Do NOT reintroduce a `pressGeneration` guard around this call. The
            // original failure was the guard, not the hop: a fast release bumped the
            // generation first and the queued arm dropped itself, capturing no audio.
            // Ordering is safe because release's disarm goes through the same queue.
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
            DictationTiming.endPress()
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
            // Adaptive: commit when frames go quiet; old fixed values are hard caps.
            let cap: TimeInterval
            if captureWasColdAtPress {
                let elapsed = utteranceBeganAt.map { Date().timeIntervalSince($0) } ?? 0
                cap = max(Self.postReleaseDrain, Self.coldStartGrace - elapsed)
            } else {
                cap = Self.postReleaseDrain
            }
            let releasedAt = Date()
            rmDebug(String(format: "🎤 Siri up — drain cap %.2fs frames=%d cold=%@",
                           cap, capture.framesSeen, captureWasColdAtPress ? "yes" : "no"))
            let work = DispatchWorkItem { [weak self] in
                self?.drainPollTick(capDeadline: releasedAt.addingTimeInterval(cap), releasedAt: releasedAt)
            }
            drainPending = true
            queue.sync {
                self.finishWorkItem = work
            }
            queue.asyncAfter(deadline: .now() + Self.drainPollInterval, execute: work)
        } else {
            // Release without a hold we own (press fell through above) — pass it
            // through as well so HID mapping sees a paired key-down/key-up.
            publishStatus()
            return false
        }
        publishStatus()
        return true
    }

    /// Runs on `queue`. Commits when voice frames have been quiet for
    /// `quietWindow`, or at `capDeadline` (old fixed-drain worst case).
    /// Utterances with no frames at all wait for the cap, as before.
    private func drainPollTick(capDeadline: Date, releasedAt: Date) {
        finishWorkItem = nil
        let now = Date()
        let quietEnough = utteranceReceivedFrame
            && now.timeIntervalSince(lastVoiceFrameAt ?? .distantPast) >= Self.quietWindow
        if quietEnough || now >= capDeadline {
            rmDebug(String(format: "🎤 drain commit after %.3fs (%@)",
                           now.timeIntervalSince(releasedAt), quietEnough ? "quiet" : "cap"))
            finishHeldUtterance()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.drainPollTick(capDeadline: capDeadline, releasedAt: releasedAt)
        }
        finishWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.drainPollInterval, execute: work)
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
                    // Fast path: type raw immediately; polish runs concurrently and
                    // lands as a guarded correction (never blocks typing).
                    self.recognitionInFlight = false
                    rmDebug("🎤 typed raw transcript len=\(text.count)")
                    self.recovery.recordTranscript(text)
                    self.publishRecoveryMode()
                    self.onTranscribedText?(text)
                    self.publishReadiness(.ready)
                    self.publishStatus()
                    let gen = self.pressGeneration
                    self.polisher.polish(text) { [weak self] polished in
                        guard let self else { return }
                        CorpusRecorder.shared.attachPolished(polished)
                        // Correction guards: unchanged press generation (no new hold
                        // or cancel), no active hold, toggle enabled, text differs.
                        guard polished != text,
                              Self.correctionEnabled,
                              self.pressGeneration == gen,
                              !self.siriHeld else { return }
                        self.recovery.recordTranscript(polished)
                        self.onReplaceTranscribedText?(text, polished)
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
            // Measure every frame and hold the loudest across the publish window.
            // Frames arrive in bursts, so publishing whichever frame happened to win a
            // 30 Hz throttle could represent a loud onset with a quiet frame.
            var sumSquares = 0.0
            var count = 0
            for index in stride(from: 0, to: pcm.count, by: 4) {
                let value = Double(pcm[index]) / 32768.0
                sumSquares += value * value
                count += 1
            }
            if count > 0 {
                let rms = sqrt(sumSquares / Double(count))
                let normalized = Float(min(1, max(0, (rms - 0.003) * 18)))
                self.pendingAudioLevelPeak = max(self.pendingAudioLevelPeak, normalized)
            }
            let now = Date.timeIntervalSinceReferenceDate
            if now - self.lastAudioLevelPublishedAt >= 1.0 / 30.0 {
                self.lastAudioLevelPublishedAt = now
                let peak = self.pendingAudioLevelPeak
                self.pendingAudioLevelPeak = 0
                DictationTiming.logOnce(.firstLevel, detail: String(format: "level=%.2f", peak))
                self.onAudioLevel?(peak)
            }
            self.lastVoiceFrameAt = Date()
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
                guard let self else { return }
                if case .success(let text) = result, let text, !text.isEmpty {
                    // Raw-first here too (disconnect/teardown path).
                    self.recognitionInFlight = false
                    self.onTranscribedText?(text)
                    self.publishReadiness(.ready)
                    self.publishStatus()
                    let gen = self.pressGeneration
                    self.polisher.polish(text) { [weak self] polished in
                        guard let self else { return }
                        CorpusRecorder.shared.attachPolished(polished)
                        guard polished != text,
                              Self.correctionEnabled,
                              self.pressGeneration == gen,
                              !self.siriHeld else { return }
                        self.onReplaceTranscribedText?(text, polished)
                    }
                    return
                }
                self.recognitionInFlight = false
                self.publishReadiness(.ready)
                self.publishStatus()
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
