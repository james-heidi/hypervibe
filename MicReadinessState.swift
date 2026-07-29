//
//  MicReadinessState.swift
//  HyperVibe
//
//  Presentation state for the remote microphone, plus the status-item chrome
//  policy. Kept dependency-free so the policy is unit-testable.
//

import Foundation

enum MicReadinessPresentationState: Equatable {
    case unavailable
    case warming(showHUD: Bool)
    case ready
    case readyToSpeak
    case listening
    case recognizing
    case releasedBeforeReady
    case error(String)

    var menuLabel: String {
        switch self {
        case .unavailable: return "麦克风：不可用"
        case .warming: return "麦克风：准备中…"
        case .ready: return "麦克风：就绪"
        case .readyToSpeak: return "麦克风：请讲"
        case .listening: return "麦克风：聆听中"
        case .recognizing: return "麦克风：转写中…"
        case .releasedBeforeReady: return "麦克风：尚未就绪"
        case .error(let message): return "麦克风：\(message)"
        }
    }
}

/// What the menu-bar status item shows. Only states caused by a Siri press may
/// replace the wave; background warm-up and retry churn (routine before the
/// helper is installed) must leave the icon alone.
enum StatusItemChrome: Equatable {
    case wave
    case spinner
    case microphone
    case waveform
}

extension MicReadinessPresentationState {
    var statusItemChrome: StatusItemChrome {
        switch self {
        case .warming(let showHUD):
            return showHUD ? .spinner : .wave
        case .recognizing:
            return .spinner
        case .readyToSpeak:
            return .microphone
        case .listening:
            return .waveform
        case .ready, .unavailable, .error, .releasedBeforeReady:
            return .wave
        }
    }
}
