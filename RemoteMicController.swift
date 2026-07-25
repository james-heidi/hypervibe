//
//  RemoteMicController.swift
//  HyperVibe
//
//  Orchestrates activation + PacketLogger capture + Opus decode + BlackHole sink.
//

import Foundation

/// End-to-end A2854 remote microphone path with zero extra hardware.
final class RemoteMicController {
    private let activator = MicActivator()
    private let capture: MicCapturePipeline
    private let hciTap = HCIEventTap()
    private let decoder: OpusVoiceDecoder?
    private let sink = BlackHoleAudioSink()
    private let queue = DispatchQueue(label: "com.hypervibe.remote-mic")

    private(set) var enabled: Bool
    private var siriHeld = false
    private var wavDebugURL: URL?
    private var wavSamples = [Int16]()

    var onStatus: ((MicCaptureStatus, String?) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "remoteMicEnabled") as? Bool ?? true
        capture = MicCapturePipeline()
        decoder = OpusVoiceDecoder()
        if decoder == nil {
            rmDebug("🎤 OpusVoiceDecoder unavailable")
        }
        capture.onStatus = { [weak self] status in
            self?.onStatus?(status, self?.sink.deviceName)
        }
        capture.onPayload = { [weak self] payload in
            self?.handlePayload(payload)
        }
    }

    var statusText: String {
        var parts = [capture.status.menuLabel]
        if let name = sink.deviceName {
            parts.append("→ \(name)")
        } else if !sink.isAvailable {
            parts.append("BlackHole 未安装")
        }
        if !enabled { return "麦克风: 已禁用" }
        return parts.joined(separator: " ")
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "remoteMicEnabled")
        if !on {
            stopSession()
        }
        publishStatus()
    }

    /// Begin PacketLogger + sink when the app launches (idle listen).
    func startIdleCaptureIfEnabled() {
        guard enabled else {
            publishStatus()
            return
        }
        if !sink.start() {
            onStatus?(.missingTools("BlackHole 2ch"), nil)
        }
        capture.start()
        hciTap.start()
        activator.arm()
        publishStatus()
    }

    /// Prefer SetReport on devices already seized by `RemoteInputHandler`.
    func attachSeizedDevices(_ devices: [IOHIDDevice]) {
        guard enabled, !devices.isEmpty else { return }
        activator.useSharedDevices(devices)
    }

    func shutdown() {
        stopSession()
        capture.stop()
        hciTap.stop()
        activator.disarm()
        sink.stop()
    }

    /// Siri button press/release from HID path.
    func handleSiri(pressed: Bool) {
        guard enabled else { return }
        if pressed {
            siriHeld = true
            activator.rearmOnSiriDown()
            decoder?.reset()
            switch capture.status {
            case .idle, .error, .missingTools:
                capture.start()
            default:
                break
            }
            _ = sink.start()
            rmDebug("🎤 Siri down — mic armed")
        } else if siriHeld {
            siriHeld = false
            sink.flushSilence()
            decoder?.reset()
            rmDebug("🎤 Siri up — silence flushed frames=\(capture.framesSeen)")
            // Optional debug dump of the last utterance
            if !wavSamples.isEmpty {
                writeDebugWAV()
                wavSamples.removeAll(keepingCapacity: true)
            }
        }
        publishStatus()
    }

    private func handlePayload(_ payload: Data) {
        queue.async {
            guard self.siriHeld || self.enabled else { return }
            guard let decoder = self.decoder else { return }
            let pcm = decoder.feed(payload)
            guard !pcm.isEmpty else { return }
            self.sink.enqueue(pcmS16: pcm)
            if self.wavSamples.count < 48_000 * 30 {
                self.wavSamples.append(contentsOf: pcm)
            }
        }
    }

    private func stopSession() {
        siriHeld = false
        sink.flushSilence()
        decoder?.reset()
    }

    private func publishStatus() {
        onStatus?(enabled ? capture.status : .idle, sink.deviceName)
    }

    private func writeDebugWAV() {
        let url = URL(fileURLWithPath: "/tmp/hypervibe-remote-mic.wav")
        do {
            try Self.writeWAV(samples: wavSamples, sampleRate: Int(OpusVoiceDecoder.sampleRate), to: url)
            rmDebug("🎤 wrote debug WAV \(url.path) samples=\(wavSamples.count)")
        } catch {
            rmDebug("🎤 WAV write failed: \(error)")
        }
    }

    static func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
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
        appendU16(1) // PCM
        appendU16(1) // mono
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
        try data.write(to: url)
    }
}
