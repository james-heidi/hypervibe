//
//  MenuBarManager.swift
//  HyperVibe
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox
import QuartzCore
import UniformTypeIdentifiers

extension NSAlert {
    /// Build an alert without the menu-bar app's placeholder icon.
    static func hyperVibeAlert() -> NSAlert {
        NSAlert()
    }

    /// NSAlert reserves a large top row for its icon even when the image is empty.
    /// Render the configured alert as a compact modal panel instead.
    @discardableResult
    func runHyperVibeModal() -> NSApplication.ModalResponse {
        HyperVibeAlertPanel(alert: self).runModal()
    }
}

private final class HyperVibeModalPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let selector: Selector?
        switch key {
        case "v": selector = #selector(NSText.paste(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        default: selector = nil
        }
        guard let selector else {
            return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(selector, to: nil, from: self)
    }
}

private final class HyperVibeAlertPanel: NSObject {
    private let alert: NSAlert
    private var panel: HyperVibeModalPanel!

    init(alert: NSAlert) {
        self.alert = alert
    }

    func runModal() -> NSApplication.ModalResponse {
        panel = HyperVibeModalPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView()
        panel.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        if !alert.messageText.isEmpty {
            let title = NSTextField(labelWithString: alert.messageText)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            stack.addArrangedSubview(title)
        }

        if !alert.informativeText.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: alert.informativeText)
            detail.font = .systemFont(ofSize: NSFont.systemFontSize)
            detail.maximumNumberOfLines = 0
            stack.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if let accessory = alert.accessoryView {
            stack.addArrangedSubview(accessory)
            accessory.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        for (index, source) in alert.buttons.enumerated().reversed() {
            let button = NSButton(
                title: source.title,
                target: self,
                action: #selector(buttonPressed(_:))
            )
            button.bezelStyle = .rounded
            button.tag = index
            if index == 0 {
                button.keyEquivalent = "\r"
            } else if index == 1 {
                button.keyEquivalent = "\u{1b}"
            }
            buttonStack.addArrangedSubview(button)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        }
        stack.addArrangedSubview(buttonStack)
        buttonStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        content.layoutSubtreeIfNeeded()
        let height = max(130, stack.fittingSize.height + 40)
        panel.setContentSize(NSSize(width: 360, height: height))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let accessory = alert.accessoryView {
            panel.makeFirstResponder(accessory)
        }

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        let rawValue = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: rawValue))
    }
}

private final class AudioWaveformView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var reactive = false

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }
    override var isOpaque: Bool { false }

    func start(reactive: Bool) {
        // Never reset amplitude here: ready→listening must not restart the animation,
        // otherwise the wave visibly snaps mid-hold.
        self.reactive = reactive
        guard timer == nil else {
            needsDisplay = true
            return
        }
        // CommonModes so the wave keeps ticking while menus/tracking runloops are up.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        needsDisplay = true
    }

    func setReactive(_ reactive: Bool) {
        self.reactive = reactive
    }

    func setLevel(_ level: Float) {
        targetLevel = CGFloat(max(0, min(1, level)))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        targetLevel = 0
        displayedLevel = 0
        reactive = false
        needsDisplay = true
    }

    /// Clear voice amplitude without stopping the breathing timer — used when the
    /// HUD hides so the next reveal is still mid-breath, not a frozen phase-0 pose.
    func clearVoiceLevel() {
        targetLevel = 0
        displayedLevel = 0
        reactive = false
        needsDisplay = true
    }

    private func tick() {
        phase += 0.10
        if reactive {
            displayedLevel += (targetLevel - displayedLevel) * 0.34
            targetLevel *= 0.88
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barCount = 7
        let barWidth: CGFloat = 5
        let spacing: CGFloat = 5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.midY

        let bars = NSBezierPath()
        for index in 0..<barCount {
            let distance = abs(CGFloat(index) - CGFloat(barCount - 1) / 2)
            let centerWeight = 1 - distance / CGFloat(barCount)
            // The breathing baseline is always present, and voice rides on top of it.
            // Ready and silent-listening therefore render identically — no collapse to
            // flat dots when the reactive state arrives before the first audio frame.
            let breath = (sin(phase + CGFloat(index) * 0.9) + 1) / 2
            var height = 7 + breath * 12 * centerWeight
            if reactive {
                let flutter = 0.72 + 0.28 * sin(phase * 1.7 + CGFloat(index) * 1.25)
                height += displayedLevel * 30 * centerWeight * flutter
            }
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + spacing),
                y: centerY - height / 2,
                width: barWidth,
                height: height
            )
            bars.append(
                NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            )
        }

        // The HUD is transparent and floats over arbitrary content. White bars carried
        // by their own drop shadow stay legible on light and dark backgrounds alike.
        NSGraphicsContext.saveGraphicsState()
        Self.barShadow.set()
        NSColor.white.setFill()
        bars.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static let barShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        return shadow
    }()
}

/// Screen-global, visual-only dictation indicator. Never activates HyperVibe.
///
/// Kept resident in the window server at `alphaValue = 0` so a Siri press is a
/// pure visibility flip + synchronous paint — no `orderFront` / first-frame hitch.
private final class MicReadinessHUD {
    private let panel: NSPanel
    private let spinner = NSProgressIndicator()
    private let waveform = AudioWaveformView()
    private let iconView = NSImageView()
    private var hideWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private(set) var isVisible = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 116, height: 62),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = content

        for view in [spinner, waveform, iconView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.isHidden = true
        }
        spinner.style = .spinning
        spinner.controlSize = .large
        // Force a light spinner so it stays readable on the same transparent HUD
        // as the white waveform (system spinning style follows appearance).
        spinner.appearance = NSAppearance(named: .darkAqua)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .white

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 32),
            spinner.heightAnchor.constraint(equalToConstant: 32),
            waveform.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 96),
            waveform.heightAnchor.constraint(equalToConstant: 54),
            iconView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
        ])

        // Resident invisible panel: first Siri press never pays orderFront latency.
        // Keep the breathing timer alive at alpha 0 so reveal is already mid-breath.
        positionOnActiveScreen()
        waveform.isHidden = false
        waveform.start(reactive: false)
        panel.orderFrontRegardless()
        panel.display()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isVisible else { return }
            self.positionOnActiveScreen()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func showWaveform(reactive: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = true
        waveform.isHidden = false
        waveform.start(reactive: reactive)
        waveform.setReactive(reactive)
        revealNow()
    }

    func updateAudioLevel(_ level: Float) {
        waveform.setLevel(level)
    }

    func showSpinner() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        waveform.stop()
        waveform.isHidden = true
        iconView.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        revealNow()
    }

    func showErrorBriefly(duration: TimeInterval = 1.2) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        waveform.stop()
        waveform.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = false
        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Microphone unavailable"
        )
        revealNow()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = true
        // Keep the breathing timer running under alpha 0. Stopping it here forced
        // every Siri press to restart at phase 0 and look frozen until the first
        // timer tick — which often arrived after HID rearm blocked main.
        waveform.clearVoiceLevel()
        waveform.isHidden = false
        waveform.start(reactive: false)
        panel.alphaValue = 0
        isVisible = false
    }

    private func revealNow() {
        if !isVisible {
            positionOnActiveScreen()
        }
        isVisible = true
        panel.alphaValue = 1
        // Paint inside this HID callback turn so the frame can composite before we
        // go on to block the runloop with IOHID SetReport / capture start.
        waveform.display()
        spinner.display()
        panel.display()
        CATransaction.flush()
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + max(72, visible.height * 0.12)
        ))
    }
}

class MenuBarManager: NSObject, NSMenuDelegate {
    private enum MenuTag {
        static let parakeetEngine = 91001
        static let downloadProgress = 91002
        static let cancelDownload = 91003
        static let engineSubmenu = 91004
    }
    
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private let micReadinessHUD = MicReadinessHUD()
    private let statusSpinner = NSProgressIndicator()
    private let profileStore: MappingProfileStore
    private var remoteConnected = false
    private var menuIsOpen = false
    private var rebuildAfterMenuCloses = false
    private(set) var trackpadControlEnabled = false
    
    // Button mappings (live copy of the active profile)
    private var buttonMappings: [String: ButtonAction] = [:]

    // Scroll speed (used for trackpad scroll scale; stored in the active profile)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    /// Set by app delegate so menu bar can delegate media actions to MediaController.
    var mediaController: MediaController?

    /// Set by AppDelegate to update touch and physical-click handling immediately.
    var onTrackpadControlToggle: ((Bool) -> Void)?
    /// Set by AppDelegate when the active profile's scroll scale changes.
    var onScrollSpeedChange: ((ScrollSpeed) -> Void)?

    /// Dictation is always on; AppDelegate ensures helper + capture after install/launch.
    var onEnsureDictationEnabled: (() -> Void)?
    var onTranscriptionEngineChange: ((TranscriptionEngineID) -> Void)?
    var onOpenAIKeySave: ((String) -> Void)?
    var onParakeetDownload: (() -> Void)?
    var onParakeetDownloadCancel: (() -> Void)?
    var onCtcModelDownload: (() -> Void)?
    var onVocabBoostEnabled: (() -> Void)?
    var onPolishModeChange: ((TranscriptPolishMode) -> Void)?
    var onOpenSetupWizard: (() -> Void)?
    var onRecoveryAction: (() -> Void)?
    var selectedTranscriptionEngine: TranscriptionEngineID = .parakeet
    var transcriptionEngineStatus = TranscriptionEngineState.idle
    var selectedPolishMode: TranscriptPolishMode = .automatic
    var polishLocalSummary = "需 macOS 26+"
    var polishCloudSummary = "需 OpenAI Key"

    init(statusItem: NSStatusItem, profileStore: MappingProfileStore = .shared) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "未连接", action: nil, keyEquivalent: "")
        self.profileStore = profileStore
        super.init()
        
        applyActiveProfile(notifyHandlers: false)
        setupMenuBar()
    }

    /// Reload menu button labels when the connected remote adapter changes.
    func noteActiveRemoteChanged() {
        requestMenuRebuild()
    }

    private func applyActiveProfile(notifyHandlers: Bool) {
        let profile = profileStore.activeProfile
        buttonMappings = profile.decodedMappings
        for (button, action) in RemoteAdapterRegistry.activeAdapter.defaultMappings
        where buttonMappings[button] == nil {
            buttonMappings[button] = action
        }
        trackpadControlEnabled = profile.trackpadControlEnabled
        scrollSpeed = profile.decodedScrollSpeed
        guard notifyHandlers else { return }
        onTrackpadControlToggle?(trackpadControlEnabled)
        onScrollSpeedChange?(scrollSpeed)
    }

    private func persistActiveMappings() {
        profileStore.updateActive(mappings: buttonMappings)
    }

    func resetMappingsToDefaults() {
        let profile = profileStore.resetActiveMappingsToAdapterDefaults()
        buttonMappings = profile.decodedMappings
        requestMenuRebuild()
    }
    
    /// Draw a compact waveform matching the global dictation HUD.
    private static func makeWaveIcon() -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            for bar in WaveGlyph.barRects(in: rect, barCount: WaveGlyph.barCount) {
                ctx.addPath(CGPath(
                    roundedRect: bar,
                    cornerWidth: bar.width / 2,
                    cornerHeight: bar.width / 2,
                    transform: nil
                ))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupMenuBar() {
        // Configure the button (the visible icon in menu bar)
        guard let button = statusItem.button else {
            return
        }
        
        button.image = Self.makeWaveIcon()
        button.title = ""

        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusSpinner)
        NSLayoutConstraint.activate([
            statusSpinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            statusSpinner.widthAnchor.constraint(equalToConstant: 16),
            statusSpinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        
        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = true
        // Probe helper once when the user opens the menu; rebuild uses cached
        // statuses afterward so we do not recurse into another probe.
        SetupCoordinator.shared.refresh(reason: .menu)
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = false
        if rebuildAfterMenuCloses {
            rebuildAfterMenuCloses = false
            rebuildMenu()
        }
    }

    /// Prefer this over `rebuildMenu()` while the status menu may be open.
    func requestMenuRebuild() {
        if menuIsOpen {
            rebuildAfterMenuCloses = true
            return
        }
        rebuildMenu()
    }

    /// Build a set of rows that pick one option out of `options`.
    ///
    /// These use `StickyMenuItemView` so the menu survives the click: AppKit
    /// unconditionally dismisses a menu after a plain `NSMenuItem` action, which
    /// made changing two settings in a row require reopening and re-navigating.
    /// A custom view handles its own mouse-up, so nothing dismisses.
    private func addStickyChoices<Option>(
        to submenu: NSMenu,
        options: [Option],
        title: @escaping (Option) -> String,
        isOn: @escaping (Option) -> Bool,
        tag: ((Option) -> Int?)? = nil,
        onSelect: @escaping (Option) -> Void
    ) {
        var views: [StickyMenuItemView] = []
        for option in options {
            let view = StickyMenuItemView(title: title(option), isOn: isOn(option)) { [weak self] in
                onSelect(option)
                // The menu stays up, so refresh the group's checkmarks in place —
                // a rebuild is deferred until the menu closes.
                for (view, option) in zip(views, options) {
                    view.isOn = isOn(option)
                    view.title = title(option)
                }
                self?.requestMenuRebuild()
            }
            let item = NSMenuItem()
            item.view = view
            if let tag = tag?(option) {
                item.tag = tag
            }
            submenu.addItem(item)
            views.append(view)
        }
        StickyMenuItemView.normalizeWidths(views)
    }

    /// A single row that runs an action and keeps the menu open.
    private func stickyItem(title: String, isOn: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = StickyMenuItemView(title: title, isOn: isOn, onClick: action)
        return item
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()

        statusMenuItem.title = connectionStatusTitle()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        addSetupMenu()

        let engineItem = NSMenuItem(title: engineMenuTitle(), action: nil, keyEquivalent: "")
        engineItem.tag = MenuTag.engineSubmenu
        let engineMenu = NSMenu()
        addStickyChoices(
            to: engineMenu,
            options: TranscriptionEngineID.allCases,
            title: { [weak self] engineID in
                var title = engineID.displayName
                guard let self else { return title }
                if engineID == .parakeet {
                    if case .downloading(let p) = self.transcriptionEngineStatus,
                       self.selectedTranscriptionEngine == .parakeet {
                        title += String(format: "（下载中 %.0f%%）", p * 100)
                    } else if !ParakeetTranscriptionEngine.modelsCached {
                        title += "（下载…）"
                    }
                } else if engineID == .openAI && !TranscriptionKeychain.hasOpenAIKeyCached {
                    title += "（需 Key）"
                }
                return title
            },
            isOn: { [weak self] engineID in self?.selectedTranscriptionEngine == engineID },
            tag: { $0 == .parakeet ? MenuTag.parakeetEngine : nil },
            onSelect: { [weak self] engineID in self?.applyTranscriptionEngine(engineID) }
        )
        engineMenu.addItem(NSMenuItem.separator())
        let openAIKeyItem = NSMenuItem(
            title: TranscriptionKeychain.hasOpenAIKeyCached ? "更换 OpenAI API Key…" : "设置 OpenAI API Key…",
            action: #selector(promptOpenAIKey(_:)),
            keyEquivalent: ""
        )
        openAIKeyItem.target = self
        engineMenu.addItem(openAIKeyItem)

        let modelMenu = NSMenu()
        addStickyChoices(
            to: modelMenu,
            options: TranscriptionEngineID.openAIModelChoices,
            title: { $0 },
            isOn: { TranscriptionEngineID.openAIModel == $0 },
            onSelect: { TranscriptionEngineID.openAIModel = $0 }
        )
        let modelItem = NSMenuItem(title: "OpenAI 模型", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        engineMenu.addItem(modelItem)

        let mirrorMenu = NSMenu()
        addStickyChoices(
            to: mirrorMenu,
            options: ModelDownloadMirror.allCases,
            title: { $0.displayName },
            isOn: { ModelDownloadMirror.current == $0 },
            onSelect: { ModelDownloadMirror.current = $0 }
        )
        let mirrorItem = NSMenuItem(title: "Parakeet 下载源", action: nil, keyEquivalent: "")
        mirrorItem.submenu = mirrorMenu
        engineMenu.addItem(mirrorItem)

        if case .downloading(let p) = transcriptionEngineStatus, selectedTranscriptionEngine == .parakeet {
            let progress = NSMenuItem(
                title: String(format: "Parakeet 下载中 %.0f%%", p * 100),
                action: nil,
                keyEquivalent: ""
            )
            progress.isEnabled = false
            progress.tag = MenuTag.downloadProgress
            engineMenu.addItem(progress)

            let cancel = NSMenuItem(
                title: "取消 Parakeet 下载",
                action: #selector(cancelParakeetDownload(_:)),
                keyEquivalent: ""
            )
            cancel.target = self
            cancel.tag = MenuTag.cancelDownload
            engineMenu.addItem(cancel)
        } else if case .preparing(let prep) = transcriptionEngineStatus, selectedTranscriptionEngine == .parakeet {
            let progress = NSMenuItem(
                title: prep.menuLabel,
                action: nil,
                keyEquivalent: ""
            )
            progress.isEnabled = false
            progress.tag = MenuTag.downloadProgress
            engineMenu.addItem(progress)

            let cancel = NSMenuItem(
                title: prep.phase == .paused ? "继续 Parakeet 下载" : "取消 Parakeet 下载",
                action: #selector(cancelParakeetDownload(_:)),
                keyEquivalent: ""
            )
            cancel.target = self
            cancel.tag = MenuTag.cancelDownload
            engineMenu.addItem(cancel)
        }

        engineMenu.addItem(NSMenuItem.separator())
        let vocabItem = NSMenuItem(title: "词表增强", action: nil, keyEquivalent: "")
        let vocabMenu = NSMenu()
        var vocabView: StickyMenuItemView?
        let vocabToggle = stickyItem(
            title: "启用词表增强",
            isOn: VocabularyStore.shared.isEnabled
        ) { [weak self] in
            VocabularyStore.shared.isEnabled.toggle()
            vocabView?.isOn = VocabularyStore.shared.isEnabled
            if VocabularyStore.shared.isEnabled { self?.onVocabBoostEnabled?() }
        }
        vocabView = vocabToggle.view as? StickyMenuItemView
        vocabToggle.toolTip = "用 CTC 关键词检测把领域词（Heidi、Claude Code…）纠正为规范写法；需先下载增强模型"
        vocabMenu.addItem(vocabToggle)
        if !ParakeetTranscriptionEngine.ctcModelsCached {
            let downloadItem = NSMenuItem(
                title: "下载增强模型（约 130 MB）…",
                action: #selector(downloadCtcModels(_:)),
                keyEquivalent: ""
            )
            downloadItem.target = self
            vocabMenu.addItem(downloadItem)
        }
        let editVocabItem = NSMenuItem(
            title: "编辑词表…",
            action: #selector(editVocabulary(_:)),
            keyEquivalent: ""
        )
        editVocabItem.target = self
        editVocabItem.toolTip = VocabularyStore.fileURL.path
        vocabMenu.addItem(editVocabItem)
        vocabItem.submenu = vocabMenu
        engineMenu.addItem(vocabItem)

        let frontEndItem = NSMenuItem(title: "音频前端（实验）", action: nil, keyEquivalent: "")
        let frontEndMenu = NSMenu()
        addStickyChoices(
            to: frontEndMenu,
            options: AudioFrontEndMode.allCases,
            title: { $0.displayName },
            isOn: { AudioFrontEndMode.current == $0 },
            onSelect: { AudioFrontEndMode.current = $0 }
        )
        frontEndItem.toolTip = "旧版为默认；语料评测通过后才切换增强前端"
        frontEndItem.submenu = frontEndMenu
        engineMenu.addItem(frontEndItem)

        var corpusView: StickyMenuItemView?
        let corpusItem = stickyItem(
            title: "录制听写语料（评测用）",
            isOn: CorpusRecorder.shared.isEnabled
        ) {
            CorpusRecorder.shared.isEnabled.toggle()
            corpusView?.isOn = CorpusRecorder.shared.isEnabled
        }
        corpusView = corpusItem.view as? StickyMenuItemView
        corpusItem.toolTip = "保存每次听写的 WAV 与转写到 ~/Library/Application Support/HyperVibe/corpus/"
        engineMenu.addItem(corpusItem)

        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let polishItem = NSMenuItem(title: "语音润色", action: nil, keyEquivalent: "")
        let polishMenu = NSMenu()
        addStickyChoices(
            to: polishMenu,
            options: TranscriptPolishMode.allCases,
            title: { $0.displayName },
            isOn: { [weak self] mode in self?.selectedPolishMode == mode },
            onSelect: { [weak self] mode in
                self?.selectedPolishMode = mode
                self?.onPolishModeChange?(mode)
            }
        )
        let localStatus = NSMenuItem(
            title: "本地：\(polishLocalSummary)",
            action: nil,
            keyEquivalent: ""
        )
        localStatus.isEnabled = false
        polishMenu.addItem(localStatus)
        let cloudStatus = NSMenuItem(
            title: "云端：\(polishCloudSummary)",
            action: nil,
            keyEquivalent: ""
        )
        cloudStatus.isEnabled = false
        polishMenu.addItem(cloudStatus)
        polishMenu.addItem(NSMenuItem.separator())
        var correctionView: StickyMenuItemView?
        let correctionItem = stickyItem(
            title: "润色后自动修正",
            isOn: RemoteMicController.correctionEnabled
        ) {
            RemoteMicController.correctionEnabled.toggle()
            correctionView?.isOn = RemoteMicController.correctionEnabled
        }
        correctionView = correctionItem.view as? StickyMenuItemView
        correctionItem.toolTip = "原文先上屏，润色完成后自动退格替换差异部分。若期间手动输入过文字请关闭。"
        polishMenu.addItem(correctionItem)

        polishItem.submenu = polishMenu
        menu.addItem(polishItem)

        addProfileMenu()
        addMappingsMenu()

        var trackpadView: StickyMenuItemView?
        let trackpadControlItem = stickyItem(title: "触控板鼠标", isOn: trackpadControlEnabled) { [weak self] in
            guard let self else { return }
            self.setTrackpadControl(!self.trackpadControlEnabled)
            trackpadView?.isOn = self.trackpadControlEnabled
        }
        trackpadView = trackpadControlItem.view as? StickyMenuItemView
        menu.addItem(trackpadControlItem)

        // Quit
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    /// Unified `安装` submenu: Accessibility, Input Monitoring, voice helper,
    /// plus a shortcut back into the onboarding wizard.
    private func addSetupMenu() {
        SetupCoordinator.shared.refresh(reason: .display)
        let statuses = SetupStep.allCases.map { SetupCoordinator.shared.statuses[$0] ?? .actionRequired }
        let setupItem = NSMenuItem(title: SetupPresentation.submenuTitle(statuses: statuses), action: nil, keyEquivalent: "")
        let setupMenu = NSMenu()
        for step in SetupStep.allCases {
            let status = SetupCoordinator.shared.statuses[step] ?? .actionRequired
            let item = NSMenuItem(
                title: SetupPresentation.menuTitle(step: step, status: status),
                action: status.isTerminalGood ? nil : #selector(performSetupStep(_:)),
                keyEquivalent: ""
            )
            item.target = status.isTerminalGood ? nil : self
            item.isEnabled = !status.isTerminalGood
            item.representedObject = step.rawValue
            setupMenu.addItem(item)
        }
        setupMenu.addItem(NSMenuItem.separator())
        let wizard = NSMenuItem(
            title: "打开安装向导…",
            action: #selector(openSetupWizard(_:)),
            keyEquivalent: ""
        )
        wizard.target = self
        setupMenu.addItem(wizard)
        if HelperInstallCoordinator.shared.readiness.isUsableForCapture {
            let uninstall = NSMenuItem(
                title: "卸载语音组件…",
                action: #selector(uninstallVoiceHelper(_:)),
                keyEquivalent: ""
            )
            uninstall.target = self
            setupMenu.addItem(uninstall)
        }
        setupItem.submenu = setupMenu
        menu.addItem(setupItem)
    }

    @objc private func performSetupStep(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let step = SetupStep(rawValue: raw) else { return }
        SetupCoordinator.shared.perform(step)
        requestMenuRebuild()
    }

    @objc private func openSetupWizard(_ sender: NSMenuItem) {
        onOpenSetupWizard?()
    }

    @objc private func uninstallVoiceHelper(_ sender: NSMenuItem) {
        let alert = NSAlert.hyperVibeAlert()
        alert.messageText = "卸载语音组件？"
        alert.informativeText = "将移除后台麦克风服务。之后听写需要重新安装。"
        alert.addButton(withTitle: "卸载…")
        alert.addButton(withTitle: "取消")
        guard alert.runHyperVibeModal() == .alertFirstButtonReturn else { return }
        HelperInstallCoordinator.shared.uninstall()
    }

    private func addProfileMenu() {
        let active = profileStore.activeProfile
        let profileItem = NSMenuItem(
            title: "配置档：\(active.name)",
            action: nil,
            keyEquivalent: ""
        )
        let profileMenu = NSMenu()
        addStickyChoices(
            to: profileMenu,
            options: profileStore.profiles,
            title: { $0.name },
            isOn: { [weak self] profile in self?.profileStore.activeProfileID == profile.id },
            onSelect: { [weak self] profile in
                self?.selectProfile(id: profile.id)
            }
        )
        profileMenu.addItem(NSMenuItem.separator())

        let actions: [(String, Selector)] = [
            ("新建…", #selector(createProfileMenu(_:))),
            ("重命名…", #selector(renameProfileMenu(_:))),
            ("复制", #selector(duplicateProfileMenu(_:))),
            ("删除…", #selector(deleteProfileMenu(_:))),
            ("导入…", #selector(importProfileMenu(_:))),
            ("导出当前…", #selector(exportActiveProfileMenu(_:))),
            ("导出全部…", #selector(exportCatalogMenu(_:))),
        ]
        for (title, selector) in actions {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            profileMenu.addItem(item)
        }
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)
    }

    private func addMappingsMenu() {
        let adapter = RemoteAdapterRegistry.activeAdapter
        let mappingsItem = NSMenuItem(title: "按键映射", action: nil, keyEquivalent: "")
        let mappingsSubmenu = NSMenu()

        for (key, label) in adapter.menuButtons {
            let buttonItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionSubmenu = NSMenu()
            let canHold = adapter.holdCapableButtons.contains(key)
            var available: [ButtonAction] = []

            for action in ButtonAction.allCases {
                if action.requiresHold && action != .backspace && !canHold { continue }
                if (action == .optionBackspace || action == .commandBackspace), key != "menu" {
                    continue
                }
                if action == .trackpadClick && key != "select" { continue }
                if action.isVoiceDictationKey { continue }
                if action.isSystemMediaKey, action != ButtonAction.nativeMediaAction(forButton: key) {
                    continue
                }
                available.append(action)
            }

            addStickyChoices(
                to: actionSubmenu,
                options: available,
                title: { $0.displayName },
                isOn: { [weak self] action in self?.buttonMappings[key] == action },
                onSelect: { [weak self] action in
                    guard let self else { return }
                    self.buttonMappings[key] = action
                    self.persistActiveMappings()
                }
            )

            buttonItem.submenu = actionSubmenu
            mappingsSubmenu.addItem(buttonItem)
        }

        mappingsSubmenu.addItem(NSMenuItem.separator())
        let resetMappings = NSMenuItem(
            title: "恢复默认按键映射",
            action: #selector(resetDefaultMappings(_:)),
            keyEquivalent: ""
        )
        resetMappings.target = self
        mappingsSubmenu.addItem(resetMappings)

        mappingsItem.submenu = mappingsSubmenu
        menu.addItem(mappingsItem)
    }

    private func selectProfile(id: UUID) {
        do {
            _ = try profileStore.select(id: id)
            applyActiveProfile(notifyHandlers: true)
            requestMenuRebuild()
        } catch {
            presentProfileError(error)
        }
    }

    @objc private func createProfileMenu(_ sender: NSMenuItem) {
        guard let name = promptProfileName(
            title: "新建配置档",
            informative: "以当前按键映射、触控板与滚动设置为起点。",
            defaultName: "新配置档"
        ) else { return }
        do {
            _ = try profileStore.create(name: name, fromCurrent: true)
            applyActiveProfile(notifyHandlers: true)
            requestMenuRebuild()
        } catch {
            presentProfileError(error)
        }
    }

    @objc private func renameProfileMenu(_ sender: NSMenuItem) {
        let current = profileStore.activeProfile
        guard let name = promptProfileName(
            title: "重命名配置档",
            informative: "当前：\(current.name)",
            defaultName: current.name
        ) else { return }
        do {
            _ = try profileStore.rename(id: current.id, to: name)
            requestMenuRebuild()
        } catch {
            presentProfileError(error)
        }
    }

    @objc private func duplicateProfileMenu(_ sender: NSMenuItem) {
        do {
            _ = try profileStore.duplicate(id: profileStore.activeProfileID)
            applyActiveProfile(notifyHandlers: true)
            requestMenuRebuild()
        } catch {
            presentProfileError(error)
        }
    }

    @objc private func deleteProfileMenu(_ sender: NSMenuItem) {
        let current = profileStore.activeProfile
        let alert = NSAlert.hyperVibeAlert()
        alert.messageText = "删除配置档？"
        alert.informativeText = "将删除「\(current.name)」。此操作不可撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runHyperVibeModal() == .alertFirstButtonReturn else { return }
        do {
            try profileStore.delete(id: current.id)
            applyActiveProfile(notifyHandlers: true)
            requestMenuRebuild()
        } catch {
            presentProfileError(error)
        }
    }

    @objc private func importProfileMenu(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "导入配置档 JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try profileStore.importJSON(data)
            for note in result.notes {
                rmDebug("🎮 profile import: \(note)")
            }
            applyActiveProfile(notifyHandlers: true)
            requestMenuRebuild()
        } catch {
            presentProfileError(error)
        }
    }

    @objc private func exportActiveProfileMenu(_ sender: NSMenuItem) {
        exportProfileData(
            filename: "\(profileStore.activeProfile.name).json",
            data: { try profileStore.exportActiveJSON() }
        )
    }

    @objc private func exportCatalogMenu(_ sender: NSMenuItem) {
        exportProfileData(
            filename: "HyperVibe-profiles.json",
            data: { try profileStore.exportCatalogJSON() }
        )
    }

    private func exportProfileData(filename: String, data: () throws -> Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data().write(to: url, options: .atomic)
        } catch {
            presentProfileError(error)
        }
    }

    private func promptProfileName(title: String, informative: String, defaultName: String) -> String? {
        let alert = NSAlert.hyperVibeAlert()
        alert.messageText = title
        alert.informativeText = informative
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runHyperVibeModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func presentProfileError(_ error: Error) {
        let alert = NSAlert.hyperVibeAlert()
        alert.messageText = "配置档操作失败"
        alert.informativeText = error.localizedDescription
        alert.runHyperVibeModal()
    }

    @objc private func resetDefaultMappings(_ sender: NSMenuItem) {
        let alert = NSAlert.hyperVibeAlert()
        alert.messageText = "恢复默认按键映射？"
        alert.informativeText = "将用当前遥控器型号的默认映射覆盖「\(profileStore.activeProfile.name)」的按键自定义。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runHyperVibeModal() == .alertFirstButtonReturn else { return }
        resetMappingsToDefaults()
    }

    private func setTrackpadControl(_ enabled: Bool) {
        trackpadControlEnabled = enabled
        profileStore.updateActive(trackpadControlEnabled: enabled)
        onTrackpadControlToggle?(enabled)
        requestMenuRebuild()
    }

    /// Connected rows name the remote model — the adapter decides button layout,
    /// so which one is live is the useful fact, not a redundant "connected".
    private func connectionStatusTitle() -> String {
        guard remoteConnected else { return "未连接" }
        return "✅ \(RemoteAdapterRegistry.activeAdapter.modelLabel)"
    }

    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let changed = self.remoteConnected != connected
            self.remoteConnected = connected
            self.statusMenuItem.title = self.connectionStatusTitle()
            self.statusItem.button?.appearsDisabled = !connected
            if changed {
                self.requestMenuRebuild()
            }
        }
    }

    func updateMicReadiness(_ state: MicReadinessPresentationState) {
        let apply = { [weak self] in
            guard let self else { return }

            // Global floating HUD first — status-item chrome is secondary.
            switch state {
            case .warming(let showHUD):
                // Keep the breathing wave during warm-up; spinner is reserved for ASR.
                if showHUD || self.micReadinessHUD.isVisible {
                    self.micReadinessHUD.showWaveform(reactive: false)
                }
            case .readyToSpeak:
                self.micReadinessHUD.showWaveform(reactive: false)
            case .listening:
                self.micReadinessHUD.showWaveform(reactive: true)
            case .recognizing:
                self.micReadinessHUD.showSpinner()
            case .releasedBeforeReady:
                self.micReadinessHUD.showErrorBriefly()
            case .error:
                self.micReadinessHUD.showErrorBriefly(duration: 2.0)
            case .ready, .unavailable:
                // HUD is press-scoped: it appears on Siri down (wave/spinner)
                // and leaves the screen once the utterance settles.
                self.micReadinessHUD.hide()
            }

            self.applyStatusIcon(for: state)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func updateMicAudioLevel(_ level: Float) {
        if Thread.isMainThread {
            micReadinessHUD.updateAudioLevel(level)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.micReadinessHUD.updateAudioLevel(level)
            }
        }
    }

    private func applyStatusIcon(for state: MicReadinessPresentationState) {
        guard let button = statusItem.button else { return }
        switch state.statusItemChrome {
        case .spinner:
            button.image = nil
            statusSpinner.startAnimation(nil)
        case .microphone:
            statusSpinner.stopAnimation(nil)
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Ready")
                ?? Self.makeWaveIcon()
        case .waveform:
            statusSpinner.stopAnimation(nil)
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Listening")
                ?? Self.makeWaveIcon()
        case .wave:
            statusSpinner.stopAnimation(nil)
            button.image = Self.makeWaveIcon()
        }
        button.appearsDisabled = !remoteConnected
    }

    private func engineMenuTitle() -> String {
        if selectedTranscriptionEngine == .parakeet {
            if case .downloading(let p) = transcriptionEngineStatus {
                return String(format: "%@（下载中 %.0f%%）", selectedTranscriptionEngine.displayName, p * 100)
            }
            if case .preparing(let prep) = transcriptionEngineStatus {
                return "\(selectedTranscriptionEngine.displayName)（\(prep.menuLabel)）"
            }
        }
        return selectedTranscriptionEngine.displayName
    }

    func updateTranscriptionEngine(id: TranscriptionEngineID, state: TranscriptionEngineState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let previousID = self.selectedTranscriptionEngine
            let previousState = self.transcriptionEngineStatus
            self.selectedTranscriptionEngine = id
            self.transcriptionEngineStatus = state

            let wasDownloading = previousState.isDownloading
            let isDownloading = state.isDownloading

            // Percent-only download updates: mutate titles, never tear down the menu tree.
            if isDownloading {
                self.applyDownloadProgressInPlace(state)
                if !wasDownloading {
                    self.ensureDownloadItemsInPlace()
                }
                return
            }

            if let engineItem = self.menu.items.first(where: { $0.tag == MenuTag.engineSubmenu }) {
                engineItem.title = self.engineMenuTitle()
            }

            let structural = previousID != id || wasDownloading || {
                switch (previousState, state) {
                case (.needsSetup, .ready), (.ready, .needsSetup),
                     (.unavailable, .ready), (.ready, .unavailable),
                     (.needsSetup, .unavailable), (.unavailable, .needsSetup),
                     (.idle, _), (_, .idle):
                    return true
                default:
                    return previousState != state
                }
            }()

            if structural {
                self.requestMenuRebuild()
            }
        }
    }

    private func engineSubmenu() -> NSMenu? {
        menu.items.first(where: { $0.tag == MenuTag.engineSubmenu })?.submenu
    }

    private func applyDownloadProgressInPlace(_ state: TranscriptionEngineState) {
        let progressTitle: String
        let percentTitle: String
        switch state {
        case .downloading(let fraction):
            progressTitle = String(format: "Parakeet 下载中 %.0f%%", fraction * 100)
            percentTitle = String(format: "Parakeet（下载中 %.0f%%）", fraction * 100)
        case .preparing(let prep):
            progressTitle = prep.menuLabel
            percentTitle = "Parakeet（\(prep.menuLabel)）"
        default:
            return
        }
        if let engineItem = menu.items.first(where: { $0.tag == MenuTag.engineSubmenu }) {
            engineItem.title = "\(TranscriptionEngineID.parakeet.displayName)（\(progressTitle)）"
        }
        if let item = engineSubmenu()?.item(withTag: MenuTag.parakeetEngine) {
            // Sticky rows draw their own text, so `item.title` would go unread.
            if let sticky = item.view as? StickyMenuItemView {
                sticky.title = percentTitle
            } else {
                item.title = percentTitle
            }
        }
        if let progress = engineSubmenu()?.item(withTag: MenuTag.downloadProgress) {
            progress.title = progressTitle
        }
    }

    private func ensureDownloadItemsInPlace() {
        guard let engineMenu = engineSubmenu() else {
            requestMenuRebuild()
            return
        }
        if engineMenu.item(withTag: MenuTag.downloadProgress) == nil {
            let progress = NSMenuItem(title: "Parakeet 下载中 0%", action: nil, keyEquivalent: "")
            progress.isEnabled = false
            progress.tag = MenuTag.downloadProgress
            engineMenu.addItem(progress)
        }
        if engineMenu.item(withTag: MenuTag.cancelDownload) == nil {
            let cancel = NSMenuItem(
                title: "取消 Parakeet 下载",
                action: #selector(cancelParakeetDownload(_:)),
                keyEquivalent: ""
            )
            cancel.target = self
            cancel.tag = MenuTag.cancelDownload
            engineMenu.addItem(cancel)
        }
    }

    private func applyTranscriptionEngine(_ id: TranscriptionEngineID) {
        selectedTranscriptionEngine = id
        onTranscriptionEngineChange?(id)
        if id == .parakeet && !ParakeetTranscriptionEngine.modelsCached {
            onParakeetDownload?()
            // Keep the open menu stable; progress updates patch titles in place.
            ensureDownloadItemsInPlace()
        } else if id == .openAI && !TranscriptionKeychain.hasOpenAIKeyCached {
            promptOpenAIKey(nil)
        }
    }

    func updatePolishStatus(
        mode: TranscriptPolishMode,
        localSummary: String,
        cloudSummary: String
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectedPolishMode = mode
            self.polishLocalSummary = localSummary
            self.polishCloudSummary = cloudSummary
            self.requestMenuRebuild()
        }
    }

    @objc private func promptOpenAIKey(_ sender: NSMenuItem?) {
        let alert = NSAlert.hyperVibeAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Key 保存在本机 Keychain，仅用于遥控器听写上传。"
        alert.alertStyle = .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "sk-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if TranscriptionKeychain.hasOpenAIKeyCached {
            alert.addButton(withTitle: "清除 Key")
        }
        let response = alert.runHyperVibeModal()
        if response == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            onOpenAIKeySave?(key)
            requestMenuRebuild()
        } else if response == .alertThirdButtonReturn {
            TranscriptionKeychain.deleteOpenAIKey()
            requestMenuRebuild()
        }
    }

    @objc private func cancelParakeetDownload(_ sender: NSMenuItem) {
        onParakeetDownloadCancel?()
    }

    @objc private func downloadCtcModels(_ sender: NSMenuItem) {
        onCtcModelDownload?()
    }

    @objc private func editVocabulary(_ sender: NSMenuItem) {
        // Ensure the file exists (seeds defaults), then open in the user's editor.
        _ = VocabularyStore.shared.terms()
        NSWorkspace.shared.open(VocabularyStore.fileURL)
    }

    func getMapping(for button: String) -> ButtonAction {
        return buttonMappings[button] ?? .none
    }
    
    /// Post the given string as a single keyboard event via `keyboardSetUnicodeString`.
    /// Works across terminals and most text fields; bypasses layout-specific key codes.
    func typeDictationText(_ text: String) {
        typeString(text)
    }

    /// Polish correction: delete the tail of the previously typed raw text that
    /// differs from the polished text, then type the polished remainder.
    /// Deletion counts grapheme clusters, matching Cocoa's delete-backward.
    // ponytail: backspace-from-end only; cursor-move diffing if corrections ever get long.
    func replaceDictationText(_ oldText: String, with newText: String) {
        guard oldText != newText else { return }
        let old = Array(oldText), new = Array(newText)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        let deleteCount = old.count - prefix
        rmDebug("🎤 polish correction delete=\(deleteCount) retype=\(new.count - prefix)")
        for _ in 0..<deleteCount {
            sendKey(kVK_Delete)
            usleep(3000)
        }
        if prefix < new.count {
            typeString(String(new[prefix...]))
        }
    }

    private func typeString(_ s: String) {
        let utf16 = Array(s.utf16)
        let count = utf16.count
        guard count > 0 else { return }
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            down?.post(tap: .cghidEventTap)
            usleep(5000)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Execute an action by name
    func executeAction(_ actionName: String) {
        guard let action = ButtonAction(rawValue: actionName) else { return }

        switch action {
        case .none:
            break
        case .enterKey:
            sendKey(kVK_Return)
        case .upKey:
            sendKey(kVK_UpArrow)
        case .downKey:
            sendKey(kVK_DownArrow)
        case .leftKey:
            sendKey(kVK_LeftArrow)
        case .rightKey:
            sendKey(kVK_RightArrow)
        case .escKey:
            sendKey(kVK_Escape)
        case .backspace:
            sendKey(kVK_Delete)
        case .optionBackspace:
            sendKey(kVK_Delete, flags: .maskAlternate)
        case .commandBackspace:
            sendKey(kVK_Delete, flags: .maskCommand)
        case .ctrlC:
            sendKey(kVK_ANSI_C, flags: .maskControl)
        case .spaceKey:
            sendKey(kVK_Space)
        case .rightCmd:
            sendModifierTap(kVK_RightCommand, flag: .maskCommand)
        case .rightOpt:
            sendModifierTap(kVK_RightOption, flag: .maskAlternate)
        case .f13Key:
            sendKey(kVK_F13)
        case .trackpadClick:
            if trackpadControlEnabled {
                performClick()
            }
        case .volumeUp:
            VolumeRevertGuard.shared.applyVolumeStep(1)
        case .volumeDown:
            VolumeRevertGuard.shared.applyVolumeStep(-1)
        case .mute:
            mediaController?.sendMediaKey(.mute)
        case .playPause:
            mediaController?.sendMediaKey(.playPause)
        case .recoverDictation:
            onRecoveryAction?()
        }
    }

    private func performClick() {
        let pos = NSEvent.mouseLocation
        let screenH = NSScreen.main?.frame.height ?? 0
        let cgPos = CGPoint(x: pos.x, y: screenH - pos.y)

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cgPos, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cgPos, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        up?.post(tap: .cghidEventTap)
    }

    /// Tap a modifier key alone (e.g. Right Command) — used to trigger push-to-talk dictation.
    private func sendModifierTap(_ keyCode: Int, flag: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = flag
        down?.post(tap: .cghidEventTap)
        usleep(10000)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }

    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}

/// A menu row that performs its action *without* closing the menu.
///
/// `NSMenuItem` with a target/action always dismisses its menu; an item carrying
/// a custom view gets the mouse event itself, so the menu stays up. That means
/// this view also owns what AppKit would normally draw: the highlight, the
/// checkmark, and the disabled text colour.
final class StickyMenuItemView: NSView {
    private static let font = NSFont.menuFont(ofSize: 0)
    /// Where AppKit starts a plain item's title. Sticky rows sit next to standard
    /// rows that AppKit lays out itself — including submenu parents, which have to
    /// stay standard for their disclosure arrow — so this has to match rather than
    /// use the wider gutter macOS adopts when it draws checkmarks itself.
    private static let titleInset: CGFloat = 16
    private static let trailingInset: CGFloat = 16
    /// Measured from `NSMenu.size`: AppKit lays out menu rows 24pt tall.
    private static let rowHeight: CGFloat = 24
    private static let minimumWidth: CGFloat = 180

    var title: String {
        didSet {
            guard title != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
        }
    }

    private let onClick: () -> Void

    init(title: String, isOn: Bool, onClick: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.rowHeight))
        frame.size = intrinsicContentSize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// Give every row in a group the same width so the highlight bars line up.
    static func normalizeWidths(_ views: [StickyMenuItemView]) {
        guard let widest = views.map(\.intrinsicContentSize.width).max() else { return }
        for view in views {
            view.frame.size = NSSize(width: widest, height: rowHeight)
        }
    }

    override var intrinsicContentSize: NSSize {
        let width = Self.titleInset + titleSize().width + Self.trailingInset
        return NSSize(width: max(width, Self.minimumWidth), height: Self.rowHeight)
    }

    private func titleSize() -> NSSize {
        (title as NSString).size(withAttributes: [.font: Self.font])
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }

        let textColor: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor]
        let textY = (bounds.height - titleSize().height) / 2

        if isOn {
            let check = "✓" as NSString
            let checkSize = check.size(withAttributes: attributes)
            check.draw(
                at: NSPoint(x: (Self.titleInset - checkSize.width) / 2, y: textY),
                withAttributes: attributes
            )
        }
        (title as NSString).draw(
            at: NSPoint(x: Self.titleInset, y: textY),
            withAttributes: attributes
        )
    }

    override func mouseUp(with event: NSEvent) {
        onClick()
    }
}
