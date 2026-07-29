//
//  PermissionState.swift
//  HyperVibe
//
//  macOS gates keystroke posting behind two per-app privacy grants that the app
//  cannot toggle itself. This exposes their live authorization state, kicks off
//  the native request flow, and deep-links the matching System Settings pane so
//  the menu bar can present a one-click setup instead of silent failures.
//

import AppKit
import ApplicationServices
import CoreGraphics

enum HyperVibePermission: CaseIterable {
    /// Posting synthesized keystrokes / reading the focused app requires this.
    case accessibility
    /// The `.cghidEventTap` media-key interceptor requires Input Monitoring.
    case inputMonitoring

    /// Whether macOS currently reports this permission as granted for this app.
    var isGranted: Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            if #available(macOS 10.15, *) {
                return CGPreflightListenEventAccess()
            }
            return true
        }
    }

    /// Trigger the native permission request. macOS shows its own prompt the
    /// first time; afterwards the user must flip the switch in System Settings,
    /// which `openSettings()` surfaces directly.
    func request() {
        switch self {
        case .accessibility:
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            if #available(macOS 10.15, *) {
                _ = CGRequestListenEventAccess()
            }
        }
    }

    /// Deep link to the exact Privacy & Security pane for this permission.
    func openSettings() {
        let urlString: String
        switch self {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Menu row title: a disabled confirmation when granted, an actionable
    /// prompt when missing. Pure function so it can be unit-tested.
    static func menuTitle(label: String, granted: Bool) -> String {
        granted ? "\(label)：已授权 ✓" : "\(label)：点击授权…"
    }

    var menuLabel: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .inputMonitoring: return "输入监控"
        }
    }
}
