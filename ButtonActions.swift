//
//  ButtonActions.swift
//  HyperVibe
//
//  Button action enum and hold-capable HID button set, shared by mapping store,
// menu, and input handler.
//

import Foundation

enum ButtonAction: String, CaseIterable {
    case enterKey = "Enter: Submit prompt"
    case upKey = "Up: Navigate Up"
    case downKey = "Down: Navigate Down"
    case leftKey = "Left: Navigate Left"
    case rightKey = "Right: Navigate Right"
    case escKey = "Esc: Navigate Back"
    case backspace = "Backspace: Delete"
    case optionBackspace = "Option + Backspace: Delete Word"
    case commandBackspace = "Command + Backspace: Delete Line"
    case ctrlC = "Control + C: Cancel Prompt"
    case spaceKey = "Space: Claude Voice Dictation"
    case rightCmd = "Right Command: 3rd-party Voice Dictation"
    case rightOpt = "Right Option: 3rd-party Voice Dictation"
    case f13Key = "F13: Custom Dictation Key"
    case trackpadClick = "Mouse Click"
    case volumeUp = "Volume Up"
    case volumeDown = "Volume Down"
    case mute = "Mute"
    case playPause = "Play/Pause"
    case recoverDictation = "Recover Last Dictation"
    case none = "None"

    var displayName: String {
        switch self {
        case .enterKey: return "Enter:发送"
        case .upKey: return "上:向上导航"
        case .downKey: return "下:向下导航"
        case .leftKey: return "左:向左导航"
        case .rightKey: return "右:向右导航"
        case .escKey: return "Esc:返回"
        case .backspace: return "退格:删除"
        case .optionBackspace: return "Option + 退格:删除上一个词"
        case .commandBackspace: return "Command + 退格:删除至行首"
        case .ctrlC: return "Control + C:取消提示"
        case .spaceKey: return "空格:Claude 语音听写"
        case .rightCmd: return "右 Command:第三方语音听写"
        case .rightOpt: return "右 Option:第三方语音听写"
        case .f13Key: return "F13:自定义听写键"
        case .trackpadClick: return "鼠标点击"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        case .mute: return "静音"
        case .playPause: return "播放/暂停"
        case .recoverDictation: return "恢复上次语音"
        case .none: return "无"
        }
    }

    static func nativeMediaAction(forButton key: String) -> ButtonAction? {
        switch key {
        case "volumeUp": return .volumeUp
        case "volumeDown": return .volumeDown
        case "mute": return .mute
        case "playPause": return .playPause
        default: return nil
        }
    }

    var isSystemMediaKey: Bool {
        switch self {
        case .volumeUp, .volumeDown, .mute, .playPause: return true
        default: return false
        }
    }

    var requiresHold: Bool {
        switch self {
        case .backspace, .spaceKey, .rightCmd, .rightOpt, .f13Key: return true
        default: return false
        }
    }

    var isVoiceDictationKey: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt, .f13Key: return true
        default: return false
        }
    }
}

/// HID buttons whose driver emits both press (value=1) and release (value=0).
let holdCapableButtons: Set<String> = [
    "playPause", "volumeUp", "volumeDown",
    "ringUp", "ringDown", "ringLeft", "ringRight", "mute",
    "siri",
]
