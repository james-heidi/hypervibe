//
//  OpusVoiceDecoder.swift
//  HyperVibe
//
//  Decode A2854 Siri Remote mic HID payloads (report 0xFA layout) to PCM.
//

import Foundation

/// Stateful Opus decoder for one A2854 microphone stream.
///
/// Wire layout of the 99-byte HID payload (report `0xFA` on Linux / ATT notify):
///   `[0..2]`  unused prefix
///   `[2..4]`  sequence number, little-endian u16
///   `[4]`     Opus frame length L
///   `[5..5+L]` Opus frame (TOC + body); TOC `0xB8` = CELT-only WB 20 ms
final class OpusVoiceDecoder {
    static let sampleRate: Int32 = 48_000
    static let channels: Int32 = 1
    static let frameDurationMs = 20
    static let frameSamples = Int(sampleRate) * frameDurationMs / 1000 // 960
    static let micReportLen = 99
    static let maxOpusFrameLen = micReportLen - 5
    static let maxPLCFrames: UInt16 = 4

    private var decoder: OpaquePointer?
    private var nextSeq: UInt16?
    private var pcmScratch = [Int16](repeating: 0, count: frameSamples)

    init?() {
        var err: Int32 = 0
        decoder = opus_decoder_create(Self.sampleRate, Self.channels, &err)
        if err != OPUS_OK || decoder == nil {
            rmDebug("🎤 Opus decoder create failed: \(err)")
            return nil
        }
    }

    deinit {
        if let decoder {
            opus_decoder_destroy(decoder)
        }
    }

    /// Parse one HID/ATT payload into `(seq, opusFrame)`.
    static func parsePacket(_ payload: Data) -> (seq: UInt16, frame: Data)? {
        guard payload.count >= 6 else { return nil }
        let seq = UInt16(payload[2]) | (UInt16(payload[3]) << 8)
        let len = Int(payload[4])
        guard len > 0, len <= maxOpusFrameLen, 5 + len <= payload.count else { return nil }
        let frame = payload.subdata(in: 5..<(5 + len))
        return (seq, frame)
    }

    /// Decode one payload into PCM samples (may include PLC frames for gaps).
    /// Returns empty array for button-release / invalid sentinels.
    func feed(_ payload: Data) -> [Int16] {
        guard let decoder else { return [] }
        guard let (seq, frame) = Self.parsePacket(payload) else {
            nextSeq = nil
            return []
        }

        var out = [Int16]()

        if let expected = nextSeq, seq != expected {
            let gap = min(UInt16(truncatingIfNeeded: seq &- expected), Self.maxPLCFrames)
            for _ in 0..<gap {
                let n = opus_decode(
                    decoder,
                    nil,
                    0,
                    &pcmScratch,
                    Int32(Self.frameSamples),
                    0
                )
                if n > 0 {
                    out.append(contentsOf: pcmScratch.prefix(Int(n)))
                }
            }
        }

        let n = frame.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return opus_decode(
                decoder,
                base,
                Int32(frame.count),
                &pcmScratch,
                Int32(Self.frameSamples),
                0
            )
        }
        if n > 0 {
            out.append(contentsOf: pcmScratch.prefix(Int(n)))
        } else {
            rmDebug("🎤 Opus decode error seq=\(seq) len=\(frame.count) rc=\(n)")
        }

        nextSeq = seq &+ 1
        return out
    }

    func reset() {
        nextSeq = nil
        // Recreate decoder — opus_decoder_ctl is unavailable from Swift (variadic).
        if let decoder {
            opus_decoder_destroy(decoder)
        }
        var err: Int32 = 0
        decoder = opus_decoder_create(Self.sampleRate, Self.channels, &err)
        if err != OPUS_OK {
            rmDebug("🎤 Opus decoder reset failed: \(err)")
            decoder = nil
        }
    }
}
