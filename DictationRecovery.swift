//
//  DictationRecovery.swift
//  HyperVibe
//
//  Runtime-only memory for the smart recovery action: retype the last polished
//  transcript, or resume an interrupted capture by merging retained PCM with a
//  short continuation. Cleared on quit; never touches disk.
//

import Foundation

enum RecoveryPendingReason: Equatable {
    case tooShort
    case emptyResult
    case engineError
    case releasedBeforeReady
    case disconnected
    case cancelled
}

enum RecoveryMode: Equatable {
    case none
    case retype(String)
    case resume(seconds: Double, RecoveryPendingReason)
}

final class DictationRecoveryStore {
    static let maxPendingSeconds: Double = 30
    static let pendingTTL: TimeInterval = 600

    private(set) var transcript: String?
    private(set) var pending: [Int16] = []
    private(set) var pendingSampleRate: Double = 48_000
    private(set) var pendingReason: RecoveryPendingReason?
    private var pendingRecordedAt: Date?
    private var transcriptRecordedAt: Date?

    var mode: RecoveryMode {
        if let text = transcript, !text.isEmpty, !isExpired(transcriptRecordedAt) {
            return .retype(text)
        }
        if !pending.isEmpty, let reason = pendingReason, !isExpired(pendingRecordedAt) {
            let seconds = Double(pending.count) / max(1, pendingSampleRate)
            return .resume(seconds: seconds, reason)
        }
        return .none
    }

    func recordTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript = trimmed
        transcriptRecordedAt = Date()
        clearPending()
    }

    func recordPending(
        _ samples: [Int16],
        sampleRate: Double = 48_000,
        reason: RecoveryPendingReason
    ) {
        guard !samples.isEmpty else { return }
        pendingSampleRate = sampleRate
        let maxSamples = Int(sampleRate * Self.maxPendingSeconds)
        if samples.count > maxSamples {
            // Keep the most recent audio so a long interrupted hold still resumes usefully.
            pending = Array(samples.suffix(maxSamples))
        } else {
            pending = samples
        }
        pendingReason = reason
        pendingRecordedAt = Date()
        transcript = nil
        transcriptRecordedAt = nil
    }

    func takePending() -> (samples: [Int16], sampleRate: Double)? {
        guard !pending.isEmpty, !isExpired(pendingRecordedAt) else { return nil }
        let samples = pending
        let rate = pendingSampleRate
        clearPending()
        return (samples, rate)
    }

    func clear() {
        transcript = nil
        transcriptRecordedAt = nil
        clearPending()
    }

    private func clearPending() {
        pending.removeAll(keepingCapacity: false)
        pendingReason = nil
        pendingRecordedAt = nil
    }

    private func isExpired(_ date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) > Self.pendingTTL
    }
}
