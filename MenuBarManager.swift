//
//  MenuBarManager.swift
//  HyperVibe
//
//  Manages the menu bar icon and menu
//

import AppKit
import Carbon.HIToolbox
import CoreImage

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
        case .none: return "无"
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

    /// Fixed allowlist for the iPhone remote. The phone sends semantic action IDs;
    /// raw virtual key codes are never accepted over the network.
    static func remoteAction(for actionID: String, pushToTalkAction: ButtonAction) -> ButtonAction? {
        switch actionID {
        case "esc": return .escKey
        case "enter": return .enterKey
        case "up": return .upKey
        case "down": return .downKey
        case "left": return .leftKey
        case "right": return .rightKey
        case "backspace": return .backspace
        case "ctrlC": return .ctrlC
        case "talk": return pushToTalkAction.requiresHold ? pushToTalkAction : nil
        default: return nil
        }
    }
}

/// HID buttons whose driver emits both press (value=1) and release (value=0) — verified via /tmp/hypervibe.log.
/// menu/tv/select are excluded: menu/tv are press-only on the Siri Remote, select is handled separately for click/drag.
let holdCapableButtons: Set<String> = [
    "playPause", "volumeUp", "volumeDown", "siri",
    "ringUp", "ringDown", "ringLeft", "ringRight", "mute",
]

/// Trackpad swipe directions (single-finger flicks). Detection happens in TouchHandler;
/// execution is dispatched here so mappings live alongside button mappings.
enum SwipeDirection: String, CaseIterable {
    case up, down, left, right
}

/// Action a swipe can trigger. Slash-command cases type the raw value (without Enter — user
/// presses Enter themselves). `leftArrow`/`rightArrow` send virtual arrow keys instead of text.
/// `init` is a Swift keyword so the case name is backtick-escaped. Raw values remain stable for
/// persistence and typing; `displayName` is used only for menu presentation.
enum SwipeAction: String, CaseIterable {
    // Priority order: direction-matched arrow (filtered per submenu), then Mode Switching,
    // then ultrathink, then slash commands alphabetically, None last.
    case leftArrow     = "Left: Navigate Left"
    case rightArrow    = "Right: Navigate Right"
    case modeSwitch    = "Mode Switching (Shift + Tab)"
    case ultrathink    = "ultrathink"
    case btw           = "/btw"
    case compact       = "/compact"
    case config        = "/config"
    case context       = "/context"
    case effort        = "/effort"
    case `init`        = "/init"
    case model         = "/model"
    case remoteControl = "/remote-control"
    case schedule      = "/schedule"
    case tasks         = "/tasks"
    case usage         = "/usage"
    case none          = "None"

    var displayName: String {
        switch self {
        case .leftArrow: return "左:向左导航"
        case .rightArrow: return "右:向右导航"
        case .modeSwitch: return "模式切换 (Shift + Tab)"
        case .ultrathink: return "ultrathink"
        case .btw: return "/btw"
        case .compact: return "/compact"
        case .config: return "/config"
        case .context: return "/context"
        case .effort: return "/effort"
        case .`init`: return "/init"
        case .model: return "/model"
        case .remoteControl: return "/remote-control"
        case .schedule: return "/schedule"
        case .tasks: return "/tasks"
        case .usage: return "/usage"
        case .none: return "无"
        }
    }

    /// Fixed semantic allowlist for tap actions from the iPhone remote.
    /// The phone never supplies text, key codes, or shortcut flags.
    static func remoteAction(for actionID: String) -> SwipeAction? {
        switch actionID {
        case "cmd_model": return .model
        case "cmd_compact": return .compact
        case "cmd_usage": return .usage
        case "cmd_context": return .context
        case "cmd_effort": return .effort
        case "cmd_tasks": return .tasks
        case "cmd_init": return .`init`
        case "kw_ultrathink": return .ultrathink
        case "mode_switch": return .modeSwitch
        default: return nil
        }
    }
}

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

class MenuBarManager {
    private static let remoteTalkActionDefaultsKey = "remoteTalkAction"
    private static let trackpadControlEnabledDefaultsKey = "trackpadControlEnabled"
    private static let remoteTalkChoices: [(action: ButtonAction, title: String)] = [
        (.spaceKey, "空格"),
        (.rightCmd, "右 Command"),
        (.rightOpt, "右 Option"),
        (.f13Key, "F13"),
    ]
    
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private var remoteServerEnabled = false
    private var remoteServerURL: String?
    private var remoteServerQRCode: NSImage?
    private var remoteServerError: String?
    private var remoteTalkAction: ButtonAction = .spaceKey
    private(set) var trackpadControlEnabled = true
    
    // Button mappings (stored in UserDefaults)
    private var buttonMappings: [String: ButtonAction] = [:]

    // Swipe gesture mappings (stored in UserDefaults under "swipeMappings").
    private var swipeMappings: [SwipeDirection: SwipeAction] = [:]

    private static let defaultSwipeMappings: [SwipeDirection: SwipeAction] = [
        .up:    .usage,
        .down:  .compact,
        .left:  .model,
        .right: .modeSwitch,
    ]

    // Scroll speed (used for trackpad scroll scale; no menu, native multitouch)
    private(set) var scrollSpeed: ScrollSpeed = .medium

    /// Set by app delegate so menu bar can delegate media actions to MediaController.
    var mediaController: MediaController?

    /// Set by AppDelegate after RemoteWebServer is created.
    var onRemoteServerToggle: ((Bool) -> Void)?

    /// Set by AppDelegate to update touch and physical-click handling immediately.
    var onTrackpadControlToggle: ((Bool) -> Void)?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.menu = NSMenu()
        self.statusMenuItem = NSMenuItem(title: "状态:未连接", action: nil, keyEquivalent: "")
        
        loadMappings()
        loadSwipeMappings()
        loadRemoteTalkAction()
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

    private func loadRemoteTalkAction() {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: Self.remoteTalkActionDefaultsKey),
           let action = ButtonAction(rawValue: rawValue),
           Self.remoteTalkChoices.contains(where: { $0.action == action }) {
            remoteTalkAction = action
        } else {
            remoteTalkAction = .spaceKey
            defaults.set(remoteTalkAction.rawValue, forKey: Self.remoteTalkActionDefaultsKey)
        }
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
            "siri": .spaceKey,
            "tv": .ctrlC
        ]

        // Schema version bumps:
        //   v3: old media-key actions removed — drop all saved button mappings
        //   v4: "select" default changed from .enterKey to .trackpadClick — reset just that entry
        //   v5: A2854 click-ring and Mute defaults added via the missing-key merge below
        let currentSchema = 5
        let savedSchema = UserDefaults.standard.integer(forKey: "buttonMappingsSchema")
        if savedSchema < 3 {
            UserDefaults.standard.removeObject(forKey: "buttonMappings")
        } else if savedSchema < 4 {
            // Targeted migration: reset "select" so the new default applies, preserve others.
            if var saved = UserDefaults.standard.dictionary(forKey: "buttonMappings") as? [String: String] {
                saved.removeValue(forKey: "select")
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
            // Defensive: if a hold-required action got persisted against a tap-only button, reset to none.
            for (button, action) in buttonMappings where action.requiresHold && !holdCapableButtons.contains(button) {
                buttonMappings[button] = ButtonAction.none
            }
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
        
        rebuildMenu()
        statusItem.menu = menu
    }
    
    private func rebuildMenu() {
        menu.removeAllItems()
        
        // Title
        let titleItem = NSMenuItem(title: "Siri 遥控器", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Status
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
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
            ("siri", "Siri 键"),
            ("playPause", "播放/暂停"),
            ("volumeUp", "音量+"),
            ("volumeDown", "音量−"),
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

        // Swipe Gestures submenu
        let swipeItem = NSMenuItem(title: "滑动手势", action: nil, keyEquivalent: "")
        let swipeSubmenu = NSMenu()
        let swipes: [(SwipeDirection, String)] = [
            (.up,    "上滑"),
            (.down,  "下滑"),
            (.left,  "左滑"),
            (.right, "右滑"),
        ]
        for (direction, label) in swipes {
            let dirItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let actionsMenu = NSMenu()
            for action in SwipeAction.allCases {
                // Each arrow-key action only appears on its matching swipe direction.
                if action == .leftArrow  && direction != .left  { continue }
                if action == .rightArrow && direction != .right { continue }

                let actionItem = NSMenuItem(title: action.displayName, action: #selector(changeSwipeMapping(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = (direction, action)
                if swipeMappings[direction] == action {
                    actionItem.state = .on
                }
                actionsMenu.addItem(actionItem)
            }
            dirItem.submenu = actionsMenu
            swipeSubmenu.addItem(dirItem)
        }
        swipeItem.submenu = swipeSubmenu
        menu.addItem(swipeItem)

        let trackpadControlItem = NSMenuItem(
            title: "触控板控制鼠标",
            action: #selector(toggleTrackpadControl(_:)),
            keyEquivalent: ""
        )
        trackpadControlItem.target = self
        trackpadControlItem.state = trackpadControlEnabled ? .on : .off
        menu.addItem(trackpadControlItem)

        // iPhone Remote submenu
        let remoteItem = NSMenuItem(title: "iPhone 遥控", action: nil, keyEquivalent: "")
        let remoteSubmenu = NSMenu()

        let enabledItem = NSMenuItem(
            title: "启用",
            action: #selector(toggleRemoteServer(_:)),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = remoteServerEnabled ? .on : .off
        remoteSubmenu.addItem(enabledItem)

        let talkKeyItem = NSMenuItem(title: "按住说话键", action: nil, keyEquivalent: "")
        let talkKeySubmenu = NSMenu()
        for choice in Self.remoteTalkChoices {
            let choiceItem = NSMenuItem(
                title: choice.title,
                action: #selector(changeRemoteTalkAction(_:)),
                keyEquivalent: ""
            )
            choiceItem.target = self
            choiceItem.representedObject = choice.action
            choiceItem.state = remoteTalkAction == choice.action ? .on : .off
            talkKeySubmenu.addItem(choiceItem)
        }
        talkKeyItem.submenu = talkKeySubmenu
        remoteSubmenu.addItem(talkKeyItem)

        if remoteServerEnabled {
            if let url = remoteServerURL {
                let urlItem = NSMenuItem(
                    title: "连接: \(url)",
                    action: #selector(copyRemoteServerURL(_:)),
                    keyEquivalent: ""
                )
                urlItem.target = self
                urlItem.toolTip = "点击复制 iPhone 遥控连接地址"
                remoteSubmenu.addItem(urlItem)

                if let qrCode = remoteServerQRCode {
                    let qrItem = NSMenuItem(
                        title: "iPhone 相机扫码连接",
                        action: #selector(copyRemoteServerURL(_:)),
                        keyEquivalent: ""
                    )
                    qrItem.target = self
                    qrItem.image = qrCode
                    qrItem.toolTip = "扫码连接，或点击复制地址"
                    remoteSubmenu.addItem(qrItem)
                }
            } else if let error = remoteServerError {
                let errorItem = NSMenuItem(title: "不可用: \(error)", action: nil, keyEquivalent: "")
                errorItem.isEnabled = false
                remoteSubmenu.addItem(errorItem)
            } else {
                let startingItem = NSMenuItem(title: "启动中…", action: nil, keyEquivalent: "")
                startingItem.isEnabled = false
                remoteSubmenu.addItem(startingItem)
            }
        }

        remoteItem.submenu = remoteSubmenu
        menu.addItem(remoteItem)

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

    @objc private func changeSwipeMapping(_ sender: NSMenuItem) {
        guard let (direction, action) = sender.representedObject as? (SwipeDirection, SwipeAction) else {
            return
        }
        swipeMappings[direction] = action
        saveSwipeMappings()
        rebuildMenu()
    }

    @objc private func changeRemoteTalkAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ButtonAction,
              Self.remoteTalkChoices.contains(where: { $0.action == action }) else { return }
        remoteTalkAction = action
        UserDefaults.standard.set(action.rawValue, forKey: Self.remoteTalkActionDefaultsKey)
        rebuildMenu()
    }
    
    func updateConnectionStatus(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusMenuItem.title = connected ? "状态:已连接 ✓" : "状态:未连接"
            self.statusItem.button?.appearsDisabled = !connected
        }
    }

    func updateRemoteServerStatus(enabled: Bool, connectURL: String?, error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.remoteServerEnabled = enabled
            if connectURL != self.remoteServerURL {
                self.remoteServerQRCode = connectURL.flatMap { Self.makeQRCode(for: $0) }
            }
            self.remoteServerURL = connectURL
            self.remoteServerError = error
            self.rebuildMenu()
        }
    }

    private static func makeQRCode(for value: String) -> NSImage? {
        guard let data = value.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        let ciContext = CIContext(options: nil)
        guard let output = filter.outputImage,
              let source = ciContext.createCGImage(output, from: output.extent.integral) else {
            return nil
        }

        // Four modules provide the standard quiet zone. Scale by a whole number so
        // every QR module remains aligned to exact pixels at approximately 180 pt.
        let quietZoneModules = 4
        let moduleWidth = source.width + quietZoneModules * 2
        let scale = max(1, Int((180.0 / CGFloat(moduleWidth)).rounded()))
        let imageWidth = moduleWidth * scale
        let imageDimension = CGFloat(imageWidth)

        guard let bitmap = CGContext(
            data: nil,
            width: imageWidth,
            height: imageWidth,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: imageDimension, height: imageDimension))
        bitmap.interpolationQuality = .none
        bitmap.setShouldAntialias(false)
        let inset = CGFloat(quietZoneModules * scale)
        bitmap.draw(source, in: CGRect(
            x: inset,
            y: inset,
            width: CGFloat(source.width * scale),
            height: CGFloat(source.height * scale)
        ))

        guard let image = bitmap.makeImage() else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: imageDimension, height: imageDimension)
        )
    }
    
    func getMapping(for button: String) -> ButtonAction {
        return buttonMappings[button] ?? .none
    }

    func getRemoteTalkAction() -> ButtonAction {
        remoteTalkAction
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
    
    private func loadSwipeMappings() {
        if let saved = UserDefaults.standard.dictionary(forKey: "swipeMappings") as? [String: String] {
            for (dirRaw, actionRaw) in saved {
                if let dir = SwipeDirection(rawValue: dirRaw),
                   let act = SwipeAction(rawValue: actionRaw) {
                    swipeMappings[dir] = act
                }
            }
        }
        // Fill any missing directions with defaults.
        for (dir, act) in Self.defaultSwipeMappings where swipeMappings[dir] == nil {
            swipeMappings[dir] = act
        }
    }

    private func saveSwipeMappings() {
        var toSave: [String: String] = [:]
        for (dir, act) in swipeMappings {
            toSave[dir.rawValue] = act.rawValue
        }
        UserDefaults.standard.set(toSave, forKey: "swipeMappings")
    }

    func getSwipeMapping(for direction: SwipeDirection) -> SwipeAction {
        return swipeMappings[direction] ?? .none
    }

    /// Execute the action bound to a swipe direction. Slash-command actions type text
    /// (no Enter — user presses Enter themselves). Arrow/modifier actions send key events.
    func executeSwipe(_ direction: SwipeDirection) {
        let action = swipeMappings[direction] ?? SwipeAction.none
        executeSwipeAction(action)
    }

    /// Shared execution path for configured swipes and allowlisted iPhone macro keys.
    func executeSwipeAction(_ action: SwipeAction) {
        switch action {
        case .none:
            break
        case .leftArrow:
            sendKey(kVK_LeftArrow)
        case .rightArrow:
            sendKey(kVK_RightArrow)
        case .modeSwitch:
            sendKey(kVK_Tab, flags: .maskShift)
        case .btw, .schedule, .ultrathink:
            // Trailing space: user typically continues with an argument or prose.
            typeString(action.rawValue + " ")
        case .compact, .config, .context, .effort, .`init`,
             .model, .remoteControl, .tasks, .usage:
            // No trailing space: these commands stand alone or open an interactive picker.
            typeString(action.rawValue)
        }
    }

    /// Post the given string as a single keyboard event via `keyboardSetUnicodeString`.
    /// Works across terminals and most text fields; bypasses layout-specific key codes.
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

    @objc private func toggleRemoteServer(_ sender: NSMenuItem) {
        onRemoteServerToggle?(!remoteServerEnabled)
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

    @objc private func copyRemoteServerURL(_ sender: NSMenuItem) {
        guard let url = remoteServerURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    
    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}
