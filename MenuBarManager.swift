//
//  MenuBarManager.swift
//  HyperVibe
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox

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

// Button actions that can be assigned
enum ButtonAction: String, CaseIterable {
    case enterKey = "Enter: Submit prompt"
    case upKey = "Up: Navigate Up"
    case downKey = "Down: Navigate Down"
    case leftKey = "Left: Navigate Left"
    case rightKey = "Right: Navigate Right"
    case escKey = "Esc: Navigate Back"
    case backspace = "Backspace: Delete"
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
        case .none: return "无"
        }
    }

    /// System media action that matches a physical Siri Remote button.
    /// Shown only in that button's mapping submenu (音量 + → 音量 +, etc.).
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

    /// Duration-sensitive actions need the virtual key held for the full physical press.
    /// Only a subset of HID buttons emit reliable release events, so these actions are
    /// offered only for hold-capable buttons.
    var requiresHold: Bool {
        switch self {
        case .backspace, .spaceKey, .rightCmd, .rightOpt, .f13Key: return true
        default: return false
        }
    }

    /// Legacy third-party dictation hotkeys, hidden from Siri Remote mappings.
    var isVoiceDictationKey: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt, .f13Key: return true
        default: return false
        }
    }
}

/// HID buttons whose driver emits both press (value=1) and release (value=0) — verified via /tmp/hypervibe.log.
/// menu/tv/select are excluded: menu/tv are press-only on the Siri Remote, select is handled separately for click/drag.
let holdCapableButtons: Set<String> = [
    "playPause", "volumeUp", "volumeDown",
    "ringUp", "ringDown", "ringLeft", "ringRight", "mute",
]

// Scroll speed options
enum ScrollSpeed: String, CaseIterable {
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"
    
    var scale: CGFloat {
        switch self {
        case .slow: return 150.0
        case .medium: return 300.0
        case .fast: return 500.0
        }
    }
}

private final class AudioWaveformView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0
    private var targetLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var reactive = false

    override var isFlipped: Bool { true }

    func start(reactive: Bool) {
        self.reactive = reactive
        if !reactive {
            targetLevel = 0
            displayedLevel = 0
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            self?.tick()
        }
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
        needsDisplay = true
    }

    private func tick() {
        phase += 0.16
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

        NSColor.labelColor.setFill()
        for index in 0..<barCount {
            let distance = abs(CGFloat(index) - CGFloat(barCount - 1) / 2)
            let centerWeight = 1 - distance / CGFloat(barCount)
            let height: CGFloat
            if reactive {
                let flutter = 0.72 + 0.28 * sin(phase * 1.7 + CGFloat(index) * 1.25)
                height = 5 + displayedLevel * 34 * centerWeight * flutter
            } else {
                // Quiet breathing motion communicates "ready" without implying speech.
                let wave = (sin(phase + CGFloat(index) * 0.9) + 1) / 2
                height = 7 + wave * 12 * centerWeight
            }
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + spacing),
                y: centerY - height / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

/// Screen-global, visual-only dictation indicator. Never activates HyperVibe.
private final class MicReadinessHUD {
    private let panel: NSPanel
    private let spinner = NSProgressIndicator()
    private let waveform = AudioWaveformView()
    private let iconView = NSImageView()
    private var hideWorkItem: DispatchWorkItem?
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

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = content

        for view in [spinner, waveform, iconView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        spinner.style = .spinning
        spinner.controlSize = .regular
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 24),
            spinner.heightAnchor.constraint(equalToConstant: 24),
            waveform.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 82),
            waveform.heightAnchor.constraint(equalToConstant: 42),
            iconView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    func showWaveform(reactive: Bool) {
        prepareToShow()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = true
        waveform.isHidden = false
        waveform.start(reactive: reactive)
        waveform.setReactive(reactive)
    }

    func updateAudioLevel(_ level: Float) {
        waveform.setLevel(level)
    }

    func showSpinner() {
        prepareToShow()
        waveform.stop()
        waveform.isHidden = true
        iconView.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func showErrorBriefly(duration: TimeInterval = 1.2) {
        prepareToShow()
        waveform.stop()
        waveform.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        iconView.isHidden = false
        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Microphone unavailable"
        )
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        spinner.stopAnimation(nil)
        waveform.stop()
        panel.orderOut(nil)
        isVisible = false
    }

    private func prepareToShow() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        positionOnActiveScreen()
        panel.orderFrontRegardless()
        isVisible = true
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
    private static let trackpadControlEnabledDefaultsKey = "trackpadControlEnabled"
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
    private var remoteConnected = false
    private var menuIsOpen = false
    private var rebuildAfterMenuCloses = false
    private(set) var trackpadControlEnabled = true
    
    // Button mappings (stored in UserDefaults)
    private var buttonMappings: [String: ButtonAction] = [:]

    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    /// Set by app delegate so menu bar can delegate media actions to MediaController.
    var mediaController: MediaController?

    /// Set by AppDelegate to update touch and physical-click handling immediately.
    var onTrackpadControlToggle: ((Bool) -> Void)?

    /// Dictation is always on; AppDelegate ensures helper + capture after install/launch.
    var onEnsureDictationEnabled: (() -> Void)?
    var onTranscriptionEngineChange: ((TranscriptionEngineID) -> Void)?
    var onOpenAIKeySave: ((String) -> Void)?
    var onParakeetDownload: (() -> Void)?
    var onParakeetDownloadCancel: (() -> Void)?
    var remoteMicEnabled = true
    var selectedTranscriptionEngine: TranscriptionEngineID = .parakeet
    var transcriptionEngineStatus = TranscriptionEngineState.idle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "未连接", action: nil, keyEquivalent: "")
        super.init()
        
        loadMappings()
        loadTrackpadControlEnabled()
        setupMenuBar()
    }

    private func loadTrackpadControlEnabled() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.trackpadControlEnabledDefaultsKey) == nil {
            defaults.set(true, forKey: Self.trackpadControlEnabledDefaultsKey)
        }
        trackpadControlEnabled = defaults.bool(forKey: Self.trackpadControlEnabledDefaultsKey)
    }

    private func loadMappings() {
        // Default mappings (only used on first launch / after schema upgrade)
        let defaultMappings: [String: ButtonAction] = [
            "playPause": .enterKey,
            "menu": .escKey,
            "select": .trackpadClick,
            "ringUp": .upKey,
            "ringDown": .downKey,
            "ringLeft": .leftKey,
            "ringRight": .rightKey,
            "volumeUp": .upKey,
            "volumeDown": .downKey,
            "mute": .none,
            "tv": .ctrlC
        ]

        // Schema version bumps:
        //   v3: old media-key actions removed — drop all saved button mappings
        //   v4: "select" default changed from .enterKey to .trackpadClick — reset just that entry
        //   v5: A2854 click-ring and Mute defaults added via the missing-key merge below
        //   v6: Siri is reserved exclusively for push-to-talk and removed from mappings
        //   v7: hide third-party voice-dictation hotkeys from Siri Remote button mappings
        let currentSchema = 7
        let savedSchema = UserDefaults.standard.integer(forKey: "buttonMappingsSchema")
        if savedSchema < 3 {
            UserDefaults.standard.removeObject(forKey: "buttonMappings")
        } else {
            if var saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
                if savedSchema < 4 {
                    // Targeted migration: reset "select" so the new default applies.
                    saved.removeValue(forKey: "select")
                }
                if savedSchema < 6 {
                    saved.removeValue(forKey: "siri")
                }
                if savedSchema < 7 {
                    for (button, raw) in saved {
                        if let action = ButtonAction(rawValue: raw), action.isVoiceDictationKey {
                            saved[button] = ButtonAction.none.rawValue
                        }
                    }
                }
                UserDefaults.standard.set(saved, forKey: "buttonMappings")
            }
        }
        if savedSchema < currentSchema {
            UserDefaults.standard.set(currentSchema, forKey: "buttonMappingsSchema")
        }

        if let saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
            for (button, actionRaw) in saved {
                if let action = ButtonAction(rawValue: actionRaw) {
                    buttonMappings[button] = action
                }
            }
            for (button, action) in defaultMappings {
                if buttonMappings[button] == nil {
                    buttonMappings[button] = action
                }
            }
            buttonMappings.removeValue(forKey: "siri")
            // Clear any leftover third-party dictation hotkeys from physical buttons.
            for (button, action) in buttonMappings where action.isVoiceDictationKey {
                buttonMappings[button] = ButtonAction.none
            }
            // Defensive: if a hold-required action got persisted against a tap-only button, reset to none.
            for (button, action) in buttonMappings where action.requiresHold && !holdCapableButtons.contains(button) {
                buttonMappings[button] = ButtonAction.none
            }
            // Persist merged defaults and sanitization so migrations survive relaunch.
            saveMappings()
        } else {
            buttonMappings = defaultMappings
            saveMappings()
        }
    }
    
    private func saveMappings() {
        var toSave: [String: String] = [:]
        for (button, action) in buttonMappings {
            toSave[button] = action.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "buttonMappings")
    }
    
    /// Procedurally draw the menu-bar icon — a walkie-talkie glyph mirroring the
    /// Figma reference (36-unit viewBox: antenna + body with display + speaker
    /// holes via even-odd fill). 2× centered scale matches the menu-bar reading
    /// size; overflow clips at the canvas edges by design.
    private static func makeWaveIcon() -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width

            ctx.translateBy(x: s / 2, y: s / 2)
            ctx.scaleBy(x: 2, y: 2)
            ctx.translateBy(x: -s / 2, y: -s / 2)

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            let antenna = CGRect(x: 0.5260 * s, y: 0.1944 * s,
                                 width: 0.0638 * s, height: 0.1594 * s)
            let body    = CGRect(x: 0.3348 * s, y: 0.3538 * s,
                                 width: 0.3187 * s, height: 0.4462 * s)
            let display = CGRect(x: 0.3986 * s, y: 0.6406 * s,
                                 width: 0.1911 * s, height: 0.0956 * s)
            let speakerR: CGFloat = 0.0956 * s
            let speaker = CGRect(x: 0.4942 * s - speakerR, y: 0.5131 * s - speakerR,
                                 width: 2 * speakerR, height: 2 * speakerR)

            let path = CGMutablePath()
            path.addPath(CGPath(roundedRect: antenna,
                                cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addPath(CGPath(roundedRect: body,
                                cornerWidth: 0.0556 * s, cornerHeight: 0.0556 * s, transform: nil))
            path.addPath(CGPath(roundedRect: display,
                                cornerWidth: 0.0278 * s, cornerHeight: 0.0278 * s, transform: nil))
            path.addEllipse(in: speaker)

            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
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
    
    private func rebuildMenu() {
        menu.removeAllItems()

        statusMenuItem.title = remoteConnected ? "已连接 ✓" : "未连接"
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        let engineItem = NSMenuItem(title: engineMenuTitle(), action: nil, keyEquivalent: "")
        engineItem.tag = MenuTag.engineSubmenu
        let engineMenu = NSMenu()
        for engineID in TranscriptionEngineID.allCases {
            var title = engineID.displayName
            if engineID == .parakeet {
                if case .downloading(let p) = transcriptionEngineStatus, selectedTranscriptionEngine == .parakeet {
                    title += String(format: "（下载中 %.0f%%）", p * 100)
                } else if !ParakeetTranscriptionEngine.modelsCached {
                    title += "（下载…）"
                }
            } else if engineID == .openAI && !TranscriptionKeychain.hasOpenAIKey {
                title += "（需 Key）"
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(selectTranscriptionEngine(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = engineID.rawValue
            item.state = selectedTranscriptionEngine == engineID ? .on : .off
            if engineID == .parakeet {
                item.tag = MenuTag.parakeetEngine
            }
            engineMenu.addItem(item)
        }
        engineMenu.addItem(NSMenuItem.separator())
        let openAIKeyItem = NSMenuItem(
            title: TranscriptionKeychain.hasOpenAIKey ? "更换 OpenAI API Key…" : "设置 OpenAI API Key…",
            action: #selector(promptOpenAIKey(_:)),
            keyEquivalent: ""
        )
        openAIKeyItem.target = self
        engineMenu.addItem(openAIKeyItem)

        let modelMenu = NSMenu()
        for model in TranscriptionEngineID.openAIModelChoices {
            let item = NSMenuItem(
                title: model,
                action: #selector(selectOpenAIModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model
            item.state = TranscriptionEngineID.openAIModel == model ? .on : .off
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "OpenAI 模型", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        engineMenu.addItem(modelItem)

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
        }

        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        // One-shot install only — once ready, no status line (noise).
        if !HCIHelperClient.isReadyCached() {
            let helperItem = NSMenuItem(
                title: "安装麦克风组件（一次性）…",
                action: #selector(installOrManageHCIHelper(_:)),
                keyEquivalent: ""
            )
            helperItem.target = self
            menu.addItem(helperItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Button Mappings submenu
        let mappingsItem = NSMenuItem(title: "按键映射", action: nil, keyEquivalent: "")
        let mappingsSubmenu = NSMenu()
        
        let buttons = [
            ("select", "触控板点击"),
            ("ringUp", "环上"),
            ("ringDown", "环下"),
            ("ringLeft", "环左"),
            ("ringRight", "环右"),
            ("menu", "返回键 ‹"),
            ("tv", "TV 键"),
            ("playPause", "播放/暂停"),
            ("volumeUp", "音量 +"),
            ("volumeDown", "音量 −"),
            ("mute", "静音键"),
        ]
        
        for (key, label) in buttons {
            let buttonItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionSubmenu = NSMenu()
            let canHold = holdCapableButtons.contains(key)

            for action in ButtonAction.allCases {
                // Hold actions require press+release tracking; hide them on tap-only buttons.
                // Backspace also works as a single tap, so it stays available everywhere.
                if action.requiresHold && action != .backspace && !canHold { continue }
                // Mouse Click is only meaningful for the trackpad click button.
                if action == .trackpadClick && key != "select" { continue }
                // Siri Remote push-to-talk is handled by the mic pipeline.
                if action.isVoiceDictationKey { continue }
                // Native media actions only appear on their matching physical button.
                if action.isSystemMediaKey, action != ButtonAction.nativeMediaAction(forButton: key) {
                    continue
                }

                let actionItem = NSMenuItem(title: action.displayName, action: #selector(changeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (key, action)

                if buttonMappings[key] == action {
                    actionItem.state = .on
                }

                actionSubmenu.addItem(actionItem)
            }

            buttonItem.submenu = actionSubmenu
            mappingsSubmenu.addItem(buttonItem)
        }
        
        mappingsItem.submenu = mappingsSubmenu
        menu.addItem(mappingsItem)

        let trackpadControlItem = NSMenuItem(
            title: "触控板鼠标",
            action: #selector(toggleTrackpadControl(_:)),
            keyEquivalent: ""
        )
        trackpadControlItem.target = self
        trackpadControlItem.state = trackpadControlEnabled ? .on : .off
        menu.addItem(trackpadControlItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc private func changeMapping(_ sender: NSMenuItem) {
        guard let (buttonKey, action) = sender.representedObject as? (String, ButtonAction) else {
            return
        }
        buttonMappings[buttonKey] = action
        saveMappings()
        rebuildMenu()
    }

    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let changed = self.remoteConnected != connected
            self.remoteConnected = connected
            self.statusMenuItem.title = connected ? "已连接 ✓" : "未连接"
            self.statusItem.button?.appearsDisabled = !connected
            if changed {
                self.requestMenuRebuild()
            }
        }
    }

    func updateRemoteMicStatus(enabled: Bool, statusText: String, sinkName: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.remoteMicEnabled = enabled
            // Live dictation state is shown by the global HUD, not in this menu row.
            _ = statusText
            _ = sinkName
        }
    }

    func updateMicReadiness(_ state: MicReadinessPresentationState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyStatusIcon(for: state)

            // Global floating HUD — visible without opening the menu.
            switch state {
            case .warming(let showHUD):
                if showHUD {
                    self.micReadinessHUD.showSpinner()
                } else if self.micReadinessHUD.isVisible {
                    self.micReadinessHUD.showSpinner()
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
                self.micReadinessHUD.hide()
            }
        }
    }

    func updateMicAudioLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.micReadinessHUD.updateAudioLevel(level)
        }
    }

    private func applyStatusIcon(for state: MicReadinessPresentationState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .warming, .recognizing:
            button.image = nil
            statusSpinner.startAnimation(nil)
        case .readyToSpeak:
            statusSpinner.stopAnimation(nil)
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Ready")
                ?? Self.makeWaveIcon()
        case .listening:
            statusSpinner.stopAnimation(nil)
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Listening")
                ?? Self.makeWaveIcon()
        case .error, .releasedBeforeReady:
            statusSpinner.stopAnimation(nil)
            button.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "麦克风未就绪"
            ) ?? Self.makeWaveIcon()
        default:
            statusSpinner.stopAnimation(nil)
            button.image = Self.makeWaveIcon()
        }
        button.appearsDisabled = !remoteConnected
    }

    private func engineMenuTitle() -> String {
        if case .downloading(let p) = transcriptionEngineStatus, selectedTranscriptionEngine == .parakeet {
            return String(format: "%@（下载中 %.0f%%）", selectedTranscriptionEngine.displayName, p * 100)
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

            let wasDownloading: Bool
            if case .downloading = previousState { wasDownloading = true } else { wasDownloading = false }
            let isDownloading: Bool
            if case .downloading = state { isDownloading = true } else { isDownloading = false }

            // Percent-only download updates: mutate titles, never tear down the menu tree.
            if isDownloading {
                if case .downloading(let p) = state {
                    self.applyDownloadProgressInPlace(p)
                }
                // First transition into downloading may need progress/cancel rows.
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

    private func applyDownloadProgressInPlace(_ fraction: Double) {
        let percentTitle = String(format: "Parakeet（下载中 %.0f%%）", fraction * 100)
        let progressTitle = String(format: "Parakeet 下载中 %.0f%%", fraction * 100)
        if let engineItem = menu.items.first(where: { $0.tag == MenuTag.engineSubmenu }) {
            engineItem.title = String(format: "%@（下载中 %.0f%%）",
                                      TranscriptionEngineID.parakeet.displayName, fraction * 100)
        }
        if let item = engineSubmenu()?.item(withTag: MenuTag.parakeetEngine) {
            item.title = percentTitle
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

    @objc private func selectTranscriptionEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = TranscriptionEngineID(rawValue: raw) else { return }
        selectedTranscriptionEngine = id
        onTranscriptionEngineChange?(id)
        if id == .parakeet && !ParakeetTranscriptionEngine.modelsCached {
            onParakeetDownload?()
            // Keep the open menu stable; progress updates patch titles in place.
            ensureDownloadItemsInPlace()
            return
        } else if id == .openAI && !TranscriptionKeychain.hasOpenAIKey {
            promptOpenAIKey(sender)
        }
        requestMenuRebuild()
    }

    @objc private func selectOpenAIModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        TranscriptionEngineID.openAIModel = model
        requestMenuRebuild()
    }

    @objc private func promptOpenAIKey(_ sender: NSMenuItem) {
        let alert = NSAlert.hyperVibeAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Key 保存在本机 Keychain，仅用于遥控器听写上传。"
        alert.alertStyle = .informational
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "sk-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if TranscriptionKeychain.hasOpenAIKey {
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

    @objc private func installOrManageHCIHelper(_ sender: NSMenuItem) {
        if HCIHelperClient.isReady() {
            let alert = NSAlert.hyperVibeAlert()
            alert.messageText = "麦克风组件"
            alert.informativeText = "后台服务已安装。按 Siri 听写无需再输入管理员密码。\n\n如需卸载，可点「卸载…」。"
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "卸载…")
            if alert.runHyperVibeModal() == .alertSecondButtonReturn {
                _ = HCIHelperClient.uninstallWithAdminPrompt()
            }
            requestMenuRebuild()
            return
        }
        if RemoteMicLab.ensureHelperInstalled(presentUI: true) {
            onEnsureDictationEnabled?()
        }
        requestMenuRebuild()
    }

    func getMapping(for button: String) -> ButtonAction {
        return buttonMappings[button] ?? .none
    }
    
    // Map HID codes to button names
    private let hidCodeToButton: [String: String] = [
        "0x000C:0x00CD": "playPause",    // Play/Pause
        "0x000C:0x00B5": "nextTrack",    // Next (not a physical button but for mapping)
        "0x000C:0x00B6": "prevTrack",    // Previous (not a physical button but for mapping)
        "0x000C:0x00E9": "volumeUp",     // Volume Up
        "0x000C:0x00EA": "volumeDown",   // Volume Down
        "0x0001:0x0086": "menu",         // Menu button (System Menu Main)
        "0x000C:0x0080": "select",       // Select button
        "0x000C:0x0040": "menu",         // Menu (alternate)
        "0x000C:0x0223": "menu",         // Home
        "0x000C:0x0224": "back",         // Back
    ]
    
    /// Get the action name for a given HID code (for event interception)
    func getMappingForHIDCode(_ hidCode: String) -> String? {
        guard let buttonName = hidCodeToButton[hidCode],
              let action = buttonMappings[buttonName] else {
            return nil
        }
        return action.rawValue
    }
    
    /// Post the given string as a single keyboard event via `keyboardSetUnicodeString`.
    /// Works across terminals and most text fields; bypasses layout-specific key codes.
    func typeDictationText(_ text: String) {
        typeString(text)
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

    @objc private func toggleTrackpadControl(_ sender: NSMenuItem) {
        trackpadControlEnabled.toggle()
        UserDefaults.standard.set(
            trackpadControlEnabled,
            forKey: Self.trackpadControlEnabledDefaultsKey
        )
        onTrackpadControlToggle?(trackpadControlEnabled)
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}
