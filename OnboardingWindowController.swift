//
//  OnboardingWindowController.swift
//  HyperVibe
//
//  First-run / incomplete-setup window for the three required install steps.
//

import AppKit

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator = SetupCoordinator.shared
    private var rows: [SetupStep: SetupStepRow] = [:]
    private var pollTimer: Timer?
    private var becomeActiveObserver: NSObjectProtocol?
    private var coordinatorObserverAttached = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 HyperVibe"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    func present() {
        attachCoordinator()
        coordinator.refresh(reason: .launch)
        reloadRows()
        startPolling()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        // Closing without finishing still counts as "seen" so we don't re-spam
        // every launch; Accessibility revoke still re-opens via shouldPresentOnLaunch.
        SetupCoordinator.markOnboardingComplete()
    }

    private func attachCoordinator() {
        guard !coordinatorObserverAttached else { return }
        coordinatorObserverAttached = true
        let previous = coordinator.onChange
        coordinator.onChange = { [weak self] in
            previous?()
            self?.reloadRows()
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator.refresh(reason: .becomeActive)
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "完成安装后即可用 Siri 遥控器听写")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "共三步。macOS 需要你在系统设置中亲自打开权限开关；HyperVibe 无法代替你授权。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(subtitle)

        for step in SetupStep.allCases {
            let row = SetupStepRow(step: step) { [weak self] step in
                self?.coordinator.perform(step)
            }
            rows[step] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
    }

    private func reloadRows() {
        var firstIncomplete: SetupStep?
        for step in SetupStep.allCases {
            let status = coordinator.statuses[step] ?? .actionRequired
            rows[step]?.update(status: status)
            if firstIncomplete == nil, !status.isTerminalGood {
                firstIncomplete = step
            }
        }
        for step in SetupStep.allCases {
            rows[step]?.setPrimary(step == firstIncomplete)
        }
        // No footer button left — dismiss once every step is done.
        if coordinator.allSatisfied {
            SetupCoordinator.markOnboardingComplete()
            window?.close()
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.coordinator.refresh(reason: .timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private final class SetupStepRow: NSView {
    private let step: SetupStep
    private let onAction: (SetupStep) -> Void
    private let badge = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "授权…", target: nil, action: nil)

    init(step: SetupStep, onAction: @escaping (SetupStep) -> Void) {
        self.step = step
        self.onAction = onAction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        badge.stringValue = "\(step.index)"
        badge.font = .boldSystemFont(ofSize: 14)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = step.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = step.explanation
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 280
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.target = self
        actionButton.action = #selector(tapped)
        actionButton.bezelStyle = .rounded
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(statusLabel)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 4),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func update(status: SetupStepStatus) {
        statusLabel.stringValue = SetupPresentation.statusDetail(step: step, status: status)
        actionButton.title = SetupPresentation.actionLabel(step: step, status: status)
        let enabled: Bool
        switch status {
        case .satisfied, .working:
            enabled = false
        case .actionRequired, .failed, .unsupported:
            enabled = true
        }
        actionButton.isEnabled = enabled
    }

    func setPrimary(_ primary: Bool) {
        if primary, actionButton.isEnabled {
            actionButton.keyEquivalent = "\r"
        } else {
            actionButton.keyEquivalent = ""
        }
    }

    @objc private func tapped() {
        onAction(step)
    }
}
