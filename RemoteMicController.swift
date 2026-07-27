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
    private let hciTap = HCIEventTap()
    private let decoder: OpusVoiceDecoder?
    private let queue = DispatchQueue(label: "com.hypervibe.remote-mic")

    private var engine: TranscriptionEngine
    private(set) var engineID: TranscriptionEngineID

    private(set) var enabled: Bool
    private var siriHeld = false
    /// Accept HCI audio from press until a short post-release drain completes.
    /// Trailing Opus frames often arrive after the HID release.
    private var acceptingAudio = false
    private var finishWorkItem: DispatchWorkItem?
    private var wavSamples = [Int16]()

    /// Wait this long after Siri-up for late HCI packets before finishing ASR.
    private static let postReleaseDrain: TimeInterval = 0.35
    /// After a cold capture start, wait up to this long for the first audio
    /// before giving up (helper bluetoothd restart alone takes ~2s).
    private static let coldStartGrace: TimeInterval = 3.0
    private var utteranceBeganAt: Date?
    private var captureWasColdAtPress = false
    /// Avoid re-arm spam (SetReport storms cut the remote mic stream after ~1s).
    private var lastRearmStatus: MicCaptureStatus?

    var onStatus: ((MicCaptureStatus, String?) -> Void)?
    var onTranscribedText: ((String) -> Void)?
    var onEngineState: ((TranscriptionEngineID, TranscriptionEngineState) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: RemoteMicLab.enabledDefaultsKey) as? Bool ?? true
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
            switch status {
            case .listening, .streaming:
                if (self.acceptingAudio || self.siriHeld), self.lastRearmStatus != status {
                    self.lastRearmStatus = status
                    self.activator.rearmOnSiriDown()
                }
            default:
                self.lastRearmStatus = nil
            }
        }
        capture.onPayload = { [weak self] payload in
            self?.handlePayload(payload)
        }
        bindEngineCallbacks()
    }

    var statusText: String {
        if !enabled { return "麦克风: 未启用" }
        var parts = [capture.status.menuLabel]
        parts.append("·\(engineID.displayName)")
        parts.append("·\(engine.state.menuLabel)")
        return parts.joined(separator: " ")
    }

    var engineState: TranscriptionEngineState { engine.state }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: RemoteMicLab.enabledDefaultsKey)
        if on {
            engine.prepare(completion: nil)
            startIdleCaptureIfEnabled()
        } else {
            stopSession(cancelRecognition: true)
            capture.stop()
            hciTap.stop()
            activator.disarm()
        }
        publishStatus()
    }

    func setEngine(_ id: TranscriptionEngineID) {
        guard id != engineID else { return }
        engine.cancel()
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

    func readiness() -> RemoteMicReadiness {
        RemoteMicLab.evaluate()
    }

    /// Prepare the selected engine and keep HCI capture warm so the first Siri
    /// press after idle isn't racing PacketLogger/bluetoothd startup (~2s).
    func startIdleCaptureIfEnabled() {
        guard enabled else {
            publishStatus()
            return
        }
        engine.prepare(completion: nil)
        hciTap.start()
        if HCIHelperClient.isReady() {
            switch capture.status {
            case .idle, .error, .missingTools:
                capture.start()
            default:
                break
            }
        }
        publishStatus()
    }

    func attachSeizedDevices(_ devices: [IOHIDDevice]) {
        guard enabled, !devices.isEmpty else { return }
        activator.useSharedDevices(devices)
        // If Siri is already held when devices reappear (bluetoothd bounce), re-arm now.
        if acceptingAudio || siriHeld {
            activator.rearmOnSiriDown()
        }
    }

    func shutdown() {
        stopSession(cancelRecognition: true)
        capture.stop()
        hciTap.stop()
        activator.disarm()
    }

    @discardableResult
    func handleSiri(pressed: Bool) -> Bool {
        guard enabled else { return false }
        if pressed {
            // If we were draining a prior hold, commit it BEFORE startUtterance clears PCM.
            let wasDraining = finishWorkItem != nil
            finishWorkItem?.cancel()
            finishWorkItem = nil
            if wasDraining {
                queue.sync { [weak self] in
                    guard let self, self.acceptingAudio else { return }
                    self.commitUtteranceLocked()
                }
            }
            guard !siriHeld else { return true }
            siriHeld = true
            lastRearmStatus = nil
            guard engine.startUtterance() else {
                siriHeld = false
                queue.async { self.acceptingAudio = false }
                if case .needsSetup(let reason) = engine.state {
                    presentEngineSetupAlert(reason)
                }
                rmDebug("🎤 Siri down — engine not ready (\(engineID.rawValue))")
                publishStatus()
                return true
            }
            activator.rearmOnSiriDown()
            decoder?.reset()
            utteranceBeganAt = Date()
            let coldStart: Bool
            switch capture.status {
            case .idle, .error, .missingTools, .starting:
                coldStart = true
            default:
                coldStart = false
            }
            captureWasColdAtPress = coldStart
            queue.async {
                self.acceptingAudio = true
                self.wavSamples.removeAll(keepingCapacity: true)
            }
            switch capture.status {
            case .idle, .error, .missingTools:
                capture.start()
            default:
                break
            }
            rmDebug("🎤 Siri down — mic armed engine=\(engineID.rawValue) coldStart=\(coldStart)")
        } else if siriHeld {
            siriHeld = false
            // Keep PushToTalk armed during drain so trailing HCI frames still arrive.
            let drain: TimeInterval
            if captureWasColdAtPress {
                let elapsed = utteranceBeganAt.map { Date().timeIntervalSince($0) } ?? 0
                // Helper bluetoothd restart alone takes ~2s before PacketLogger streams.
                drain = max(Self.postReleaseDrain, Self.coldStartGrace - elapsed)
            } else {
                drain = Self.postReleaseDrain
            }
            rmDebug(String(format: "🎤 Siri up — draining %.2fs frames=%d cold=%@",
                           drain, capture.framesSeen, captureWasColdAtPress ? "yes" : "no"))
            let work = DispatchWorkItem { [weak self] in
                self?.finishHeldUtterance()
            }
            finishWorkItem = work
            queue.asyncAfter(deadline: .now() + drain, execute: work)
        }
        publishStatus()
        return true
    }

    private func finishHeldUtterance() {
        // Runs on `queue` so acceptingAudio / wavSamples stay consistent with payloads.
        finishWorkItem = nil
        activator.disarm()
        commitUtteranceLocked()
    }

    private func commitUtteranceLocked() {
        acceptingAudio = false
        let debugSamples = wavSamples
        wavSamples.removeAll(keepingCapacity: true)
        rmDebug("🎤 recognition finishing frames=\(capture.framesSeen) debugSamples=\(debugSamples.count)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.decoder?.reset()
            self.engine.finishUtterance { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    if let text, !text.isEmpty {
                        rmDebug("🎤 typed transcript len=\(text.count)")
                        self.onTranscribedText?(text)
                    } else {
                        rmDebug("🎤 transcript empty — no typing")
                    }
                case .failure(let error):
                    // Accidental taps / cold-start races produce empty audio — not a real failure.
                    if let te = error as? TranscriptionEngineError, case .emptyAudio = te {
                        rmDebug("🎤 empty utterance ignored")
                    } else {
                        self.presentTranscriptionFailure(error)
                    }
                }
                self.publishStatus()
            }
            if !debugSamples.isEmpty {
                self.writeDebugWAV(samples: debugSamples)
            }
            self.publishStatus()
        }
    }

    private func bindEngineCallbacks() {
        engine.onState = { [weak self] state in
            guard let self else { return }
            self.onEngineState?(self.engineID, state)
            self.publishStatus()
        }
    }

    private func handlePayload(_ payload: Data) {
        queue.async {
            guard self.acceptingAudio else { return }
            guard let decoder = self.decoder else { return }
            let pcm = decoder.feed(payload)
            guard !pcm.isEmpty else { return }
            self.engine.append(pcmS16: pcm, sampleRate: Double(OpusVoiceDecoder.sampleRate))
            if self.wavSamples.count < 48_000 * 30 {
                self.wavSamples.append(contentsOf: pcm)
            }
        }
    }

    private func stopSession(cancelRecognition: Bool) {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        siriHeld = false
        queue.async { self.acceptingAudio = false }
        activator.disarm()
        if cancelRecognition {
            engine.cancel()
        } else {
            engine.finishUtterance { [weak self] result in
                if case .success(let text) = result, let text, !text.isEmpty {
                    self?.onTranscribedText?(text)
                }
                self?.publishStatus()
            }
        }
        decoder?.reset()
    }

    private func publishStatus() {
        onStatus?(enabled ? capture.status : .idle, nil)
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
