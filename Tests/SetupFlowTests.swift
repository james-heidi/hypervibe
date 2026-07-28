import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct SetupFlowTests {
    static func main() {
        testStepOrderAndCopy()
        testMenuTitles()
        testRowStatusDetailOmitsTitle()
        testSubmenuBadge()
        testActionLabels()
        testInstallStateBusyness()
        testFailureMessages()
        testFreshCoordinatorAsksForEveryStep()
        testOnboardingVersionGate()
        print("SetupFlowTests: PASS")
    }

    private static func testStepOrderAndCopy() {
        expect(SetupStep.allCases == [.accessibility, .inputMonitoring, .voiceHelper], "step order is stable")
        expect(SetupStep.accessibility.index == 1, "steps are numbered from 1")
        expect(SetupStep.voiceHelper.index == 3, "voice helper is step 3")
        for step in SetupStep.allCases {
            expect(!step.title.isEmpty, "\(step) needs a title")
            expect(!step.explanation.isEmpty, "\(step) needs an explanation of why it is required")
        }
        expect(SetupStep.accessibility.permission == .accessibility, "accessibility maps to its TCC grant")
        expect(SetupStep.inputMonitoring.permission == .inputMonitoring, "input monitoring maps to its TCC grant")
        expect(SetupStep.voiceHelper.permission == nil, "the helper install is not a TCC grant")
    }

    private static func testMenuTitles() {
        expect(
            SetupPresentation.menuTitle(step: .accessibility, status: .satisfied) == "1 辅助功能：已完成 ✓",
            "satisfied rows confirm completion, got \(SetupPresentation.menuTitle(step: .accessibility, status: .satisfied))"
        )
        expect(
            SetupPresentation.menuTitle(step: .accessibility, status: .actionRequired) == "1 辅助功能：点击授权…",
            "permission rows prompt to authorize"
        )
        expect(
            SetupPresentation.menuTitle(step: .inputMonitoring, status: .actionRequired) == "2 输入监控：点击授权…",
            "permission rows prompt to authorize"
        )
        expect(
            SetupPresentation.menuTitle(step: .voiceHelper, status: .actionRequired) == "3 语音组件：安装…",
            "the helper row prompts to install, not to authorize"
        )
        expect(
            SetupPresentation.menuTitle(step: .voiceHelper, status: .working("安装中…")) == "3 语音组件：安装中…",
            "working rows show the in-flight detail verbatim"
        )
        expect(
            SetupPresentation.menuTitle(step: .voiceHelper, status: .failed("已取消")) == "3 语音组件：失败 — 已取消",
            "failed rows surface the reason"
        )
        expect(
            SetupPresentation.menuTitle(step: .voiceHelper, status: .unsupported("缺少内置组件"))
                == "3 语音组件：缺少内置组件",
            "unsupported rows explain why the step cannot run"
        )
    }

    /// The wizard row already renders the number and title, so its status line
    /// must not repeat them (it read "3 语音组件：安装…" under the description).
    private static func testRowStatusDetailOmitsTitle() {
        for step in SetupStep.allCases {
            let statuses: [SetupStepStatus] = [
                .satisfied, .actionRequired, .working("安装中…"),
                .failed("后台服务未响应"), .unsupported("缺少内置组件"),
            ]
            for status in statuses {
                let detail = SetupPresentation.statusDetail(step: step, status: status)
                expect(!detail.contains(step.title), "\(step) \(status) status line repeats the title: \(detail)")
                expect(!detail.contains("\(step.index)"), "\(step) \(status) status line repeats the index: \(detail)")
                expect(!detail.isEmpty, "\(step) \(status) needs a status line")
            }
        }
        expect(
            SetupPresentation.statusDetail(step: .voiceHelper, status: .actionRequired) == "待安装",
            "the helper row says what is pending"
        )
        expect(
            SetupPresentation.statusDetail(step: .voiceHelper, status: .failed("后台服务未响应"))
                == "失败 — 后台服务未响应",
            "failures surface the reason"
        )
    }

    private static func testSubmenuBadge() {
        expect(
            SetupPresentation.submenuTitle(statuses: [.satisfied, .satisfied, .satisfied]) == "安装 ✓",
            "a fully set-up app gets a checkmark"
        )
        expect(
            SetupPresentation.submenuTitle(statuses: [.actionRequired, .actionRequired, .failed("x")]) == "安装 ⚠︎",
            "nothing done yet gets a warning"
        )
        expect(
            SetupPresentation.submenuTitle(statuses: [.satisfied, .satisfied, .actionRequired]) == "安装（2/3）",
            "partial progress is counted, got \(SetupPresentation.submenuTitle(statuses: [.satisfied, .satisfied, .actionRequired]))"
        )
        expect(
            SetupPresentation.submenuTitle(statuses: [.satisfied, .working("安装中…"), .failed("x")]) == "安装（1/3）",
            "in-flight and failed steps do not count as done"
        )
    }

    private static func testActionLabels() {
        expect(
            SetupPresentation.actionLabel(step: .accessibility, status: .satisfied) == "已完成",
            "satisfied steps show a disabled-style label"
        )
        expect(
            SetupPresentation.actionLabel(step: .accessibility, status: .actionRequired) == "授权…",
            "permission steps offer authorization"
        )
        expect(
            SetupPresentation.actionLabel(step: .voiceHelper, status: .actionRequired) == "安装…",
            "the helper step offers installation"
        )
        expect(
            SetupPresentation.actionLabel(step: .voiceHelper, status: .working("验证中…")) == "进行中…",
            "in-flight steps do not invite a second click"
        )
        expect(
            SetupPresentation.actionLabel(step: .voiceHelper, status: .failed("boom")) == "重试",
            "failures are retryable"
        )
        expect(
            !SetupPresentation.actionLabel(step: .voiceHelper, status: .unsupported("x")).isEmpty,
            "unsupported steps still label their button"
        )
    }

    private static func testInstallStateBusyness() {
        expect(!HelperInstallState.idle(.unknown).isBusy, "idle is not busy")
        expect(!HelperInstallState.idle(.ready).isBusy, "idle is not busy")
        expect(!HelperInstallState.failed(.userCancelled).isBusy, "a failed install is not busy")
        expect(HelperInstallState.probing.isBusy, "probing is busy")
        expect(HelperInstallState.awaitingAuthorization.isBusy, "waiting on the admin prompt is busy")
        expect(HelperInstallState.installing.isBusy, "installing is busy")
        expect(HelperInstallState.verifying(attempt: 1, total: 5).isBusy, "verifying is busy")

        // Re-entry guard depends on readiness snapshots never blocking the caller.
        expect(HelperInstallCoordinator.shared.readiness == .unknown, "readiness starts unknown until first probe")
        expect(!HelperInstallCoordinator.shared.isReady, "unknown readiness is not ready")

        // A pre-VERSION daemon still captures; only the upgrade prompt differs.
        expect(HelperReadiness.ready.isUsableForCapture, "ready helper captures")
        expect(
            HelperReadiness.outdated(installed: 0, expected: 2).isUsableForCapture,
            "outdated helper still captures so dictation is not silently disabled"
        )
        expect(!HelperReadiness.notInstalled.isUsableForCapture, "missing helper cannot capture")
        expect(!HelperReadiness.unknown.isUsableForCapture, "unprobed helper cannot capture")

        // Regression: a silent daemon must never look like a successful install.
        // Probing during the launchd restart window used to report `.outdated`,
        // which verification accepted — the wizard then said "安装…" forever even
        // though the helper had actually been installed.
        expect(!HelperReadiness.unresponsive.isResponding, "silent daemon is not proof of install")
        expect(!HelperReadiness.unresponsive.isUsableForCapture, "silent daemon cannot capture")
        expect(HelperReadiness.ready.isResponding, "ready daemon responded")
        expect(
            HelperReadiness.outdated(installed: 0, expected: 2).isResponding,
            "pre-VERSION daemon answered PING, so the install did work"
        )
        expect(!HelperReadiness.notInstalled.isResponding, "missing helper never responds")
    }

    private static func testFailureMessages() {
        expect(HelperInstallFailure.userCancelled.userMessage == "已取消", "cancellation is not an error report")
        expect(!HelperInstallFailure.bundledHelperMissing.userMessage.isEmpty, "missing helper explains itself")
        expect(!HelperInstallFailure.verificationTimedOut.userMessage.isEmpty, "verification timeout explains itself")
        expect(!HelperInstallFailure.timedOut.userMessage.isEmpty, "authorization timeout explains itself")
        expect(
            HelperInstallFailure.authorizationFailed("").userMessage == "管理员授权失败",
            "an empty authorization error still reads as one"
        )

        let noisy = String(repeating: "x", count: 500)
        let message = HelperInstallFailure.scriptFailed(exitCode: 3, stderrSnippet: noisy).userMessage
        expect(message.count == 240, "script stderr is truncated for the UI, got \(message.count) chars")
        expect(
            !HelperInstallFailure.scriptFailed(exitCode: 3, stderrSnippet: "").userMessage.isEmpty,
            "a silent script failure still reports something"
        )
    }

    private static func testFreshCoordinatorAsksForEveryStep() {
        // Constructing the shared coordinator must not perform socket or admin work.
        let statuses = SetupCoordinator.shared.statuses
        expect(statuses.count == SetupStep.allCases.count, "every step has a status before the first refresh")
        for step in SetupStep.allCases {
            expect(statuses[step] == .actionRequired, "\(step) starts as actionRequired, not satisfied")
        }
    }

    private static func testOnboardingVersionGate() {
        let defaults = UserDefaults.standard
        let key = SetupCoordinator.onboardingCompletedVersionKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        expect(SetupCoordinator.currentOnboardingVersion == 1, "onboarding version is 1")
        defaults.removeObject(forKey: key)
        expect(SetupCoordinator.shouldPresentOnLaunch(), "a first launch presents onboarding")

        SetupCoordinator.markOnboardingComplete()
        expect(
            defaults.integer(forKey: key) == SetupCoordinator.currentOnboardingVersion,
            "completing onboarding records the version that was completed"
        )

        // Revoked Accessibility silently breaks typing, so the wizard must come back
        // even after completion. Ad-hoc test binaries are never trusted, so this
        // assertion only holds when the grant really is missing.
        if !HyperVibePermission.accessibility.isGranted {
            expect(
                SetupCoordinator.shouldPresentOnLaunch(),
                "revoked Accessibility re-presents onboarding"
            )
        }

        defaults.set(SetupCoordinator.currentOnboardingVersion - 1, forKey: key)
        expect(SetupCoordinator.shouldPresentOnLaunch(), "an older completed version re-presents onboarding")
    }
}
