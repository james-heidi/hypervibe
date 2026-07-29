//
//  SetupFlow.swift
//  HyperVibe
//
//  Shared model for the first-run onboarding window and the menu-bar 安装
//  submenu. Permission grants still require System Settings; this only explains,
//  requests, deep-links, and reflects live status.
//

import AppKit
import Foundation

enum SetupStep: Int, CaseIterable {
    case accessibility = 0
    case inputMonitoring = 1
    case voiceHelper = 2

    var index: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .inputMonitoring: return "输入监控"
        case .voiceHelper: return "语音组件"
        }
    }

    var explanation: String {
        switch self {
        case .accessibility:
            return "允许 HyperVibe 把听写结果输入到当前应用。"
        case .inputMonitoring:
            return "拦截遥控器媒体键，避免误触发系统音量或音乐。"
        case .voiceHelper:
            return "一次性安装后台麦克风服务，之后听写不再弹出密码框。"
        }
    }

    var permission: HyperVibePermission? {
        switch self {
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        case .voiceHelper: return nil
        }
    }
}

enum SetupStepStatus: Equatable {
    case satisfied
    case actionRequired
    case working(String)
    case failed(String)
    case unsupported(String)

    var isTerminalGood: Bool { self == .satisfied }
}

enum SetupPresentation {
    static func menuTitle(step: SetupStep, status: SetupStepStatus) -> String {
        let prefix = "\(step.index) \(step.title)"
        switch status {
        case .satisfied:
            return "\(prefix)：已完成 ✓"
        case .actionRequired:
            switch step {
            case .accessibility, .inputMonitoring:
                return "\(prefix)：点击授权…"
            case .voiceHelper:
                return "\(prefix)：安装…"
            }
        case .working(let detail):
            return "\(prefix)：\(detail)"
        case .failed(let detail):
            return "\(prefix)：失败 — \(detail)"
        case .unsupported(let detail):
            return "\(prefix)：\(detail)"
        }
    }

    /// Status line for the wizard rows, which already show the number and title.
    static func statusDetail(step: SetupStep, status: SetupStepStatus) -> String {
        switch status {
        case .satisfied:
            return "已完成 ✓"
        case .actionRequired:
            switch step {
            case .accessibility, .inputMonitoring:
                return "待授权"
            case .voiceHelper:
                return "待安装"
            }
        case .working(let detail):
            return detail
        case .failed(let detail):
            return "失败 — \(detail)"
        case .unsupported(let detail):
            return detail
        }
    }

    /// Aggregate badge for the top-level 安装 item.
    static func submenuTitle(statuses: [SetupStepStatus]) -> String {
        let total = statuses.count
        let done = statuses.filter { $0.isTerminalGood }.count
        if done == total { return "安装 ✓" }
        if done == 0 { return "安装 ⚠︎" }
        return "安装（\(done)/\(total)）"
    }

    static func actionLabel(step: SetupStep, status: SetupStepStatus) -> String {
        switch status {
        case .satisfied:
            return "已完成"
        case .actionRequired:
            switch step {
            case .accessibility, .inputMonitoring: return "授权…"
            case .voiceHelper: return "安装…"
            }
        case .working:
            return "进行中…"
        case .failed:
            return "重试"
        case .unsupported:
            return "查看说明"
        }
    }
}

final class SetupCoordinator {
    static let shared = SetupCoordinator()
    static let onboardingCompletedVersionKey = "onboardingCompletedVersion"
    static let currentOnboardingVersion = 1

    private(set) var statuses: [SetupStep: SetupStepStatus] = [:]
    var onChange: (() -> Void)?
    /// Fired on main when Input Monitoring transitions to granted so the app
    /// can restart the media-key event tap.
    var onInputMonitoringGranted: (() -> Void)?

    private var previousInputGranted = false

    private init() {
        for step in SetupStep.allCases {
            statuses[step] = .actionRequired
        }
        HelperInstallCoordinator.shared.addOnChange(id: "setup") { [weak self] in
            self?.refresh(reason: .helper)
        }
    }

    enum RefreshReason {
        case launch
        case menu
        case timer
        case becomeActive
        case helper
        case action
        /// Recompute UI from cached helper/permission state without probing.
        case display
    }

    func refresh(reason: RefreshReason) {
        var next: [SetupStep: SetupStepStatus] = [:]
        next[.accessibility] = HyperVibePermission.accessibility.isGranted
            ? .satisfied : .actionRequired
        next[.inputMonitoring] = HyperVibePermission.inputMonitoring.isGranted
            ? .satisfied : .actionRequired
        next[.voiceHelper] = voiceStatus(from: HelperInstallCoordinator.shared.state)

        let inputNow = next[.inputMonitoring] == .satisfied
        let gainedInput = inputNow && !previousInputGranted
        previousInputGranted = inputNow

        statuses = next
        onChange?()

        if gainedInput {
            onInputMonitoringGranted?()
        }

        // Kick a background probe when UI is looking at helper status. The wizard's
        // `.timer` must probe too: a status captured while launchd was restarting the
        // daemon would otherwise stay wrong for as long as the window is open.
        // `.display` is cache-only (menu rebuild / onChange fan-out) so we never
        // re-enter HelperInstallCoordinator → menu rebuild → probe forever.
        switch reason {
        case .launch, .menu, .becomeActive, .action, .timer:
            HelperInstallCoordinator.shared.refresh(reason: String(describing: reason))
        case .helper, .display:
            break
        }
    }

    func perform(_ step: SetupStep) {
        switch step {
        case .accessibility, .inputMonitoring:
            guard let permission = step.permission else { return }
            permission.request()
            permission.openSettings()
            refresh(reason: .action)
        case .voiceHelper:
            switch HelperInstallCoordinator.shared.state {
            case .idle(.ready):
                break
            case .idle(.outdated):
                HelperInstallCoordinator.shared.install()
            case .failed, .idle:
                HelperInstallCoordinator.shared.install()
            case .probing, .awaitingAuthorization, .installing, .verifying:
                break
            }
            refresh(reason: .action)
        }
    }

    var allSatisfied: Bool {
        SetupStep.allCases.allSatisfy { statuses[$0]?.isTerminalGood == true }
    }

    static func shouldPresentOnLaunch() -> Bool {
        let completed = UserDefaults.standard.integer(forKey: onboardingCompletedVersionKey)
        if completed < currentOnboardingVersion { return true }
        // Revoked Accessibility silently breaks typing — force the wizard back.
        if !HyperVibePermission.accessibility.isGranted { return true }
        return false
    }

    static func markOnboardingComplete() {
        UserDefaults.standard.set(currentOnboardingVersion, forKey: onboardingCompletedVersionKey)
    }

    private func voiceStatus(from state: HelperInstallState) -> SetupStepStatus {
        switch state {
        case .idle(.ready):
            return .satisfied
        case .idle(.outdated):
            return .actionRequired
        case .idle(.unresponsive):
            return .failed("后台服务未响应")
        case .idle(.notInstalled), .idle(.unknown):
            if HCIHelperPaths.bundledHelperURL() == nil {
                return .unsupported("缺少内置组件")
            }
            return .actionRequired
        case .probing:
            return .working("检测中…")
        case .awaitingAuthorization:
            return .working("等待授权…")
        case .installing:
            return .working("安装中…")
        case .verifying(let attempt, let total):
            return .working("验证中…（\(attempt)/\(total)）")
        case .failed(let failure):
            return .failed(failure.userMessage)
        }
    }
}
