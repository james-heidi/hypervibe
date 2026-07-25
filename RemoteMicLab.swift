//
//  RemoteMicLab.swift
//  HyperVibe
//
//  Lab-mode remote mic: readiness checks, setup wizard, profile-expiry reminders.
//  Core HyperVibe (buttons/trackpad) does not require any of this.
//

import AppKit
import Foundation

/// Snapshot of whether the privileged A2854 → BlackHole path can work on this Mac.
struct RemoteMicReadiness {
    var packetLogger: Bool
    var bluetoothProfile: Bool
    var blackHole: Bool
    var remoteAddress: String?
    var passwordlessPacketLogger: Bool
    /// Profile was seen before but is gone now (typical ~3-day Apple logging profile).
    var profileLikelyExpired: Bool
    /// Profile present but approaching the usual ~3-day window.
    var profileExpiringSoon: Bool

    var isReady: Bool {
        packetLogger && bluetoothProfile && blackHole && remoteAddress != nil
    }

    var checklistText: String {
        func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }
        var lines = [
            "\(mark(packetLogger)) PacketLogger (Additional Tools for Xcode)",
            "\(mark(bluetoothProfile)) Bluetooth 日志配置描述文件",
            "\(mark(blackHole)) BlackHole 2ch",
            "\(mark(remoteAddress != nil)) Siri Remote 已配对\(remoteAddress.map { " (\($0))" } ?? "")",
            "\(mark(passwordlessPacketLogger)) PacketLogger 免密 sudo（可选，否则每次需授权）",
        ]
        if profileLikelyExpired {
            lines.append("⚠ Bluetooth 配置似乎已过期 — 需重新安装（通常约 3 天）")
        } else if profileExpiringSoon {
            lines.append("⚠ Bluetooth 配置可能即将过期 — 建议提前重装")
        }
        return lines.joined(separator: "\n")
    }
}

/// Lab helpers shared by menu, launch checks, and CLI `--mic-check`.
enum RemoteMicLab {
    static let enabledDefaultsKey = "remoteMicEnabled"
    static let profileSeenAtKey = "remoteMicProfileLastSeenAt"
    static let expiryAlertDayKey = "remoteMicExpiryAlertDay"
    static let wizardShownKey = "remoteMicWizardShown"

    /// Apple’s Bluetooth logging profiles are typically short-lived (~3 days).
    private static let profileLifetime: TimeInterval = 3 * 24 * 60 * 60
    private static let profileWarnBefore: TimeInterval = 12 * 60 * 60

    static let profileDownloadURL = URL(string:
        "https://developer.apple.com/services-account/download?path=/OS_X/OS_X_Logs/Bluetooth_macOS.mobileconfig"
    )!
    static let profileHelpURL = URL(string:
        "https://developer.apple.com/feedback-assistant/profiles-and-logs/?platform=macos&name=bluetooth"
    )!
    static let additionalToolsURL = URL(string:
        "https://developer.apple.com/download/all/?q=Additional%20Tools%20for%20Xcode"
    )!
    static let docsURL = URL(string:
        "https://github.com/james-heidi/hypervibe/blob/main/docs/remote-mic.md"
    )!

    static func evaluate() -> RemoteMicReadiness {
        let profile = MicCapturePipeline.bluetoothProfileInstalled()
        let defaults = UserDefaults.standard
        let now = Date()

        if profile {
            if defaults.object(forKey: profileSeenAtKey) == nil {
                // Seed from managed-prefs mtime so expiry math tracks install, not first app launch.
                let seeded = profileInstallProxyDate() ?? now
                defaults.set(seeded.timeIntervalSince1970, forKey: profileSeenAtKey)
            }
            // Refresh "last seen" while profile is present (does not reset the install clock).
            // Keep the earlier of stored install proxy and now-3d so we don't push expiry forever.
        } else if defaults.object(forKey: profileSeenAtKey) != nil {
            // keep stored timestamp for expiry detection
        }

        let seenAt = defaults.object(forKey: profileSeenAtKey) as? Double
        var likelyExpired = false
        var expiringSoon = false

        if let seenAt {
            let age = now.timeIntervalSince1970 - seenAt
            if !profile && age > 60 {
                likelyExpired = true
            } else if profile && age >= profileLifetime - profileWarnBefore {
                expiringSoon = true
            }
        } else if !profile {
            // Never seen a profile on this Mac.
        }

        // When profile returns after expiry, reset the install clock.
        if profile, defaults.bool(forKey: "remoteMicProfileWasMissing") {
            defaults.set(now.timeIntervalSince1970, forKey: profileSeenAtKey)
            defaults.set(false, forKey: "remoteMicProfileWasMissing")
        }
        if !profile {
            defaults.set(true, forKey: "remoteMicProfileWasMissing")
        }

        let sink = BlackHoleAudioSink()
        return RemoteMicReadiness(
            packetLogger: MicCapturePipeline.packetLoggerURL() != nil,
            bluetoothProfile: profile,
            blackHole: sink.isAvailable,
            remoteAddress: MicCapturePipeline.detectRemoteAddress(),
            passwordlessPacketLogger: passwordlessPacketLoggerAllowed(),
            profileLikelyExpired: likelyExpired,
            profileExpiringSoon: expiringSoon
        )
    }

    private static func profileInstallProxyDate() -> Date? {
        let paths = [
            "/Library/Managed Preferences/com.apple.MobileBluetooth.debug.plist",
            "/Library/Managed Preferences/com.apple.corecapture.configure.bt.plist",
        ]
        var oldest: Date?
        for path in paths {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let date = attrs[.modificationDate] as? Date else { continue }
            if oldest == nil || date < oldest! {
                oldest = date
            }
        }
        return oldest
    }

    static func passwordlessPacketLoggerAllowed() -> Bool {
        guard let logger = MicCapturePipeline.packetLoggerURL() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "-l", logger.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func sudoersSnippet() -> String {
        let path = MicCapturePipeline.packetLoggerURL()?.path
            ?? "/Applications/PacketLogger.app/Contents/Resources/packetlogger"
        return "%admin ALL=(root) NOPASSWD: \(path)\n"
    }

    static func copySudoersToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sudoersSnippet(), forType: .string)
    }

    static func openProfileInstall() {
        NSWorkspace.shared.open(profileHelpURL)
        NSWorkspace.shared.open(profileDownloadURL)
    }

    static func openPacketLoggerHelp() {
        NSWorkspace.shared.open(additionalToolsURL)
    }

    static func openDocs() {
        NSWorkspace.shared.open(docsURL)
    }

    /// Consumer mic is parked after the durable-capture spike failed
    /// (see docs/spike-durable-capture.md). Keep the message short — no setup wizard.
    static func presentUnavailableMessage() {
        let alert = NSAlert()
        alert.messageText = "遥控器麦克风暂不可用"
        alert.informativeText = """
        当前 macOS 没有可用的零外设采集通道，普通安装无法稳定使用遥控器麦克风。

        按键和触控板不受影响。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "技术说明")
        if alert.runModal() == .alertSecondButtonReturn {
            openDocs()
        }
    }

    /// After GATE FAIL, never auto-enable from readiness alone in the menu path.
    /// Developers can still force-enable via CLI (`--capture-mic`) or defaults.
    static var consumerMicParked: Bool { true }

    /// Present the Lab setup wizard. Returns whether the user chose to enable Lab mic.
    @discardableResult
    static func presentWizard(
        allowingEnable: Bool = true,
        reason: String? = nil
    ) -> Bool {
        let readiness = evaluate()
        let alert = NSAlert()
        alert.messageText = "远程麦克风 Lab 设置"
        var info = """
        这是实验功能：用 PacketLogger 嗅探 HCI，再经 Opus 解码写入 BlackHole。
        按键/触控板不依赖此路径。

        \(readiness.checklistText)
        """
        if let reason, !reason.isEmpty {
            info = reason + "\n\n" + info
        }
        if readiness.isReady {
            info += "\n\n就绪后：听写 App 输入选 BlackHole 2ch → 按住 Siri 说话。"
        } else {
            info += "\n\n请先完成缺失项，或运行：./scripts/setup_remote_mic.sh"
        }
        alert.informativeText = info
        alert.alertStyle = readiness.isReady ? .informational : .warning

        enum Action {
            case enable, profile, packetLogger, sudoers, close
        }

        var actions: [Action] = []
        if allowingEnable {
            alert.addButton(withTitle: readiness.isReady ? "启用 Lab" : "仍要启用")
            actions.append(.enable)
        }
        alert.addButton(withTitle: "安装 Bluetooth 配置…")
        actions.append(.profile)
        alert.addButton(withTitle: "PacketLogger 说明…")
        actions.append(.packetLogger)
        alert.addButton(withTitle: "复制 sudoers")
        actions.append(.sudoers)
        alert.addButton(withTitle: "关闭")
        actions.append(.close)

        UserDefaults.standard.set(true, forKey: wizardShownKey)

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0, index < actions.count else { return false }

        switch actions[index] {
        case .enable:
            return true
        case .profile:
            openProfileInstall()
            return false
        case .packetLogger:
            openPacketLoggerHelp()
            return false
        case .sudoers:
            copySudoersToPasteboard()
            let copied = NSAlert()
            copied.messageText = "已复制到剪贴板"
            copied.informativeText = """
            不要直接粘贴到终端（zsh 会把 %admin 当特殊语法）。

            在终端执行：
            sudo visudo -f /etc/sudoers.d/hypervibe-packetlogger

            在打开的编辑器里粘贴这一行并保存：
            \(sudoersSnippet().trimmingCharacters(in: .newlines))
            """
            copied.addButton(withTitle: "好")
            copied.runModal()
            return false
        case .close:
            return false
        }
    }

    /// First launch after Lab ships: show the setup checklist once so users can find it.
    /// Returns `true` if the user chose to enable Lab from that prompt.
    @discardableResult
    static func maybePresentFirstRunWizardIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: wizardShownKey) else { return false }
        return presentWizard(
            allowingEnable: true,
            reason: "远程麦克风是实验 Lab 功能（按键/触控板不依赖它）。下面是一次性设置清单；就绪后可点「启用 Lab」。"
        )
    }

    /// Once per calendar day while Lab is on and profile is missing/expired/expiring.
    static func maybePresentExpiryReminderIfNeeded(labEnabled: Bool) {
        guard labEnabled else { return }
        let readiness = evaluate()
        guard readiness.profileLikelyExpired
            || readiness.profileExpiringSoon
            || !readiness.bluetoothProfile else { return }

        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let dayKey = String(day)
        if UserDefaults.standard.string(forKey: expiryAlertDayKey) == dayKey {
            return
        }
        UserDefaults.standard.set(dayKey, forKey: expiryAlertDayKey)

        let reason: String
        if readiness.profileLikelyExpired || !readiness.bluetoothProfile {
            reason = "Bluetooth 日志配置已失效或未安装。远程麦克风 Lab 需要重新安装描述文件（通常约 3 天有效）。"
        } else {
            reason = "Bluetooth 日志配置可能即将过期。建议现在重装，以免采集中断。"
        }

        let alert = NSAlert()
        alert.messageText = "远程麦克风 Lab"
        alert.informativeText = reason + "\n\n" + readiness.checklistText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "安装配置…")
        alert.addButton(withTitle: "打开设置向导")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openProfileInstall()
        case .alertSecondButtonReturn:
            _ = presentWizard(allowingEnable: false, reason: reason)
        default:
            break
        }
    }
}
