//
//  ModelPreparation.swift
//  HyperVibe
//
//  Progress mapping and download-mirror helpers for the Parakeet prepare pipeline.
//  Bytes map to 0…0.85; compile maps to 0.85…1.0 so the menu never sticks at 100%
//  while CoreML is still compiling.
//

import Foundation
import FluidAudio

struct ModelPrepProgress: Equatable {
    enum Phase: Equatable {
        case listing
        case downloading(files: Int, total: Int)
        case compiling(String)
        case warmup
        case stalled(seconds: Int)
        case retrying
        case paused
    }

    var phase: Phase
    /// Overall 0…1 fraction for the menu / HUD.
    var fraction: Double
    var bytesPerSecond: Double?
    var etaSeconds: Int?

    var menuLabel: String {
        let pct = Int((fraction * 100).rounded(.down))
        switch phase {
        case .listing:
            return "列出文件…"
        case .downloading(let files, let total):
            var parts = [String(format: "下载中 %d%%", pct)]
            if total > 0 {
                parts.append("（\(files)/\(total)）")
            }
            if let bps = bytesPerSecond, bps > 0 {
                parts.append(String(format: "，%.1f MB/s", bps / 1_000_000))
            }
            if let eta = etaSeconds, eta > 0 {
                parts.append("，约 \(Self.formatETA(eta))")
            }
            return parts.joined()
        case .compiling(let name):
            return "编译模型 \(name)…"
        case .warmup:
            return "加载模型…"
        case .stalled(let seconds):
            return "下载停滞 \(seconds)s — 可重试或切换镜像"
        case .retrying:
            return "网络重试中…"
        case .paused:
            return "已暂停"
        }
    }

    static func formatETA(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        return String(format: "%.0f 小时", Double(seconds) / 3600.0)
    }

    /// Map a FluidAudio download-phase fraction into the overall 0…0.85 byte band.
    static func fromDownloadFraction(_ fraction: Double, filesCompleted: Int = 0, filesTotal: Int = 0) -> ModelPrepProgress {
        let clamped = max(0, min(1, fraction))
        return ModelPrepProgress(
            phase: .downloading(files: filesCompleted, total: filesTotal),
            fraction: clamped * 0.85,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
    }

    static func compiling(name: String, step: Int, total: Int) -> ModelPrepProgress {
        let base = 0.85
        let span = 0.12
        let t = total > 0 ? Double(step) / Double(total) : 1
        return ModelPrepProgress(
            phase: .compiling(name),
            fraction: base + span * t,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
    }

    static let warmup = ModelPrepProgress(phase: .warmup, fraction: 0.98, bytesPerSecond: nil, etaSeconds: nil)
    static let paused = ModelPrepProgress(phase: .paused, fraction: 0, bytesPerSecond: nil, etaSeconds: nil)
}

enum ModelDownloadMirror: String, CaseIterable {
    case official = "https://huggingface.co"
    case hfMirror = "https://hf-mirror.com"

    static let defaultsKey = "parakeetDownloadMirror"

    var displayName: String {
        switch self {
        case .official: return "官方 huggingface.co"
        case .hfMirror: return "镜像 hf-mirror.com"
        }
    }

    static var current: ModelDownloadMirror {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let value = ModelDownloadMirror(rawValue: raw) else {
                return .official
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            applyToRegistry()
        }
    }

    /// Must run before any FluidAudio download call (and again after mirror switch).
    static func applyToRegistry() {
        ModelRegistry.baseURL = current.rawValue
        rmDebug("🎤 Parakeet mirror=\(current.rawValue)")
    }
}

/// Throttle helper: publish on phase change, percent change, or ≥250ms elapsed.
final class ModelProgressThrottle {
    private var lastPhase: ModelPrepProgress.Phase?
    private var lastPercent = -1
    private var lastPublishedAt = Date.distantPast
    private let minInterval: TimeInterval = 0.25

    func shouldPublish(_ progress: ModelPrepProgress) -> Bool {
        let percent = Int((progress.fraction * 100).rounded(.down))
        let now = Date()
        let phaseChanged = progress.phase != lastPhase
        let percentChanged = percent != lastPercent
        let elapsed = now.timeIntervalSince(lastPublishedAt) >= minInterval
        guard phaseChanged || (percentChanged && elapsed) || (phaseChanged == false && elapsed && percentChanged) else {
            // Always allow first publish / phase transitions immediately.
            if lastPhase == nil || phaseChanged {
                lastPhase = progress.phase
                lastPercent = percent
                lastPublishedAt = now
                return true
            }
            return false
        }
        lastPhase = progress.phase
        lastPercent = percent
        lastPublishedAt = now
        return true
    }

    func reset() {
        lastPhase = nil
        lastPercent = -1
        lastPublishedAt = Date.distantPast
    }
}
