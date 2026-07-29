//
//  AudioFrontEnd.swift
//  HyperVibe
//
//  Whole-utterance audio conditioning before ASR. Deterministic: no state
//  survives between calls. `legacy` = the original peak normalization.
//
//  KEEP IN SYNC with tools/stt-eval/ParakeetEvalCLI/Sources/AudioFrontEnd.swift
//  (byte-identical output is asserted by the eval harness parity check).
//

import Foundation

enum AudioFrontEndMode: String, CaseIterable {
    case legacy = "legacy"
    case conditioned = "conditioned"

    static let defaultsKey = "audioFrontEndMode"

    /// Legacy stays default until the corpus gate passes (see openspec spec).
    static var current: AudioFrontEndMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let mode = AudioFrontEndMode(rawValue: raw) {
                return mode
            }
            return .legacy
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .legacy: return "旧版（峰值归一）"
        case .conditioned: return "增强（滤波+AGC）"
        }
    }
}

enum AudioFrontEnd {
    // Conditioning constants (tuned against the recorded corpus).
    private static let highPassHz = 80.0
    private static let frameLen = 960                 // 20 ms @ 48 kHz
    private static let targetSpeechRMS: Float = 0.1   // ≈ −20 dBFS
    private static let maxGain: Float = 40.0          // remote audio peaks ~2k/32767
    private static let limiterKnee: Float = 0.95
    private static let gateDepth: Float = 0.3         // multiplier for noise-floor frames
    private static let gateThresholdRatio: Float = 0.1 // 20 dB below speech RMS

    static func process(_ samples: [Int16], sampleRate: Int, mode: AudioFrontEndMode) -> [Int16] {
        switch mode {
        case .legacy:
            return PCMWaveWriter.boostForASR(samples)
        case .conditioned:
            return condition(samples, sampleRate: sampleRate)
        }
    }

    private static func condition(_ samples: [Int16], sampleRate: Int) -> [Int16] {
        guard !samples.isEmpty else { return samples }
        var x = samples.map { Float($0) / 32768.0 }

        // 1. Biquad high-pass (RBJ, Q = 0.707) — remove sub-speech rumble.
        let w0 = 2.0 * Double.pi * highPassHz / Double(sampleRate)
        let cosw0 = cos(w0), sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * 0.7071)
        let a0 = 1 + alpha
        let b0 = Float(((1 + cosw0) / 2) / a0)
        let b1 = Float((-(1 + cosw0)) / a0)
        let b2 = b0
        let a1 = Float((-2 * cosw0) / a0)
        let a2 = Float((1 - alpha) / a0)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<x.count {
            let xn = x[i]
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xn; y2 = y1; y1 = yn
            x[i] = yn
        }

        // 2. Speech-level estimate: RMS of the loudest quartile of 20 ms frames,
        //    so leading/trailing silence doesn't drag the gain estimate.
        var frameRMS: [Float] = []
        var i = 0
        while i < x.count {
            let end = min(i + frameLen, x.count)
            var sum: Float = 0
            for j in i..<end { sum += x[j] * x[j] }
            frameRMS.append(sqrt(sum / Float(end - i)))
            i = end
        }
        let sorted = frameRMS.sorted(by: >)
        let quartile = max(1, sorted.count / 4)
        let speechRMS = sorted[0..<quartile].reduce(0, +) / Float(quartile)
        guard speechRMS > 0 else { return samples }

        // 3. Gain toward target speech level, capped.
        let gain = min(maxGain, targetSpeechRMS / speechRMS)

        // 4. Downward gate per frame (well below speech floor), with linear
        //    cross-frame interpolation to avoid clicks. Then gain + soft limiter.
        let gateThreshold = speechRMS * gateThresholdRatio
        var frameGain = frameRMS.map { $0 < gateThreshold ? gateDepth : Float(1.0) }
        if frameGain.count == 1 { frameGain[0] = 1.0 } // single frame: never gate everything

        var out = [Int16](repeating: 0, count: x.count)
        for idx in 0..<x.count {
            let f = idx / frameLen
            let posInFrame = Float(idx % frameLen) / Float(frameLen)
            let g0 = frameGain[min(f, frameGain.count - 1)]
            let g1 = frameGain[min(f + 1, frameGain.count - 1)]
            let gGate = g0 + (g1 - g0) * posInFrame
            var v = x[idx] * gain * gGate
            // Soft limiter above the knee instead of hard clipping.
            let mag = abs(v)
            if mag > limiterKnee {
                let over = mag - limiterKnee
                let limited = limiterKnee + (1.0 - limiterKnee) * tanhf(over / (1.0 - limiterKnee))
                v = v < 0 ? -limited : limited
            }
            out[idx] = Int16(max(-32768.0, min(32767.0, (v * 32767.0).rounded())))
        }
        return out
    }
}
