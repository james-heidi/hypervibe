//
//  RemoteInputHandler.swift
//  HyperVibe
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit

class RemoteInputHandler {
    private struct HeldKey {
        let id: UUID
        let keyCode: Int
        let flags: CGEventFlags
        let repeatTimer: DispatchSourceTimer
    }

    private let cursorController: CursorController
    private weak var menuBarManager: MenuBarManager?
    private let mediaController = MediaController()
    private var devices: [IOHIDDevice] = []
    
    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?

    /// Siri button press/release for the remote-mic pipeline. Return true to consume
    /// the normal mapped action while push-to-talk dictation is enabled.
    var onSiriMic: ((Bool) -> Bool)?
    
    // First press after connection: do not perform action (sound already played at connect).
    private var isFirstPressAfterConnection = false
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectPressTime: UInt64 = 0
    private var isDragging = false
    private var trackpadControlEnabled = true
    private let clickThreshold: Double = 0.25
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    static func machDeltaToSeconds(from start: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let delta = mach_absolute_time() - start
        return Double(delta) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Virtual keys currently held down, keyed by the HID button that initiated the hold.
    /// Captured at press time so release can fire the correct keyUp even if the user
    /// rebinds the button mid-hold. Cleared on device removal to avoid stuck modifiers.
    private var heldKeys: [String: HeldKey] = [:]

    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    
    init(cursorController: CursorController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
    }

    /// HID devices currently opened/seized for the paired remote.
    var seizedDevices: [IOHIDDevice] { devices }

    func setTrackpadControlEnabled(_ enabled: Bool) {
        trackpadControlEnabled = enabled
        guard !enabled else { return }

        // Cancel a pending Select click and release an active drag immediately.
        isSelectPressed = false
        cursorController.isClickActive = false
        if isDragging {
            cursorController.isDragging = false
            cursorController.mouseUp()
        }
        isDragging = false
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            releaseAllHeldKeys()
            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            isFirstPressAfterConnection = false
            return
        }
        
        guard !devices.contains(where: { $0 == device }) else { return }
        
        // Seize device to prevent system from handling events
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if openResult == kIOReturnSuccess {
            rmDebug(String(format: "🔒 SEIZED HID device (vendor=0x%X product=0x%X)",
                  IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0,
                  IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0))
            IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            devices.append(device)
            isFirstPressAfterConnection = true
        } else {
            rmDebug(String(format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized", openResult))
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                devices.append(device)
                isFirstPressAfterConnection = true
            }
        }
    }
    
    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let identified = identifyButton(page: usagePage, usage: usage)
        rmDebug(String(format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
                       usagePage, usage, intValue, identified ?? "<unmapped>"))
        guard let buttonName = identified else { return }

        onButtonActivity?()

        // Collapse mirrored-interface duplicates: only proceed on a real state transition.
        let isPressed = (intValue == 1)
        if buttonState[buttonName] == isPressed {
            return
        }
        buttonState[buttonName] = isPressed

        // Volume keys also travel over BT AVRCP absolute-volume. Arm the revert guard for
        // remapped actions so AVRCP doesn't change the level. Native volume mapping applies
        // its own sticky CoreAudio hold inside applyVolumeStep.
        if isPressed && (buttonName == "volumeUp" || buttonName == "volumeDown") {
            let mapped = menuBarManager?.getMapping(for: buttonName) ?? .none
            if mapped != ButtonAction.nativeMediaAction(forButton: buttonName) {
                VolumeRevertGuard.shared.armFromRemoteButton()
            }
        }

        // First key-down after connection: skip so the connect handshake doesn't fire
        // an action. Siri is exempt — a press to dictate must count even when it's the
        // press that woke/reconnected the remote.
        if intValue == 1 && isFirstPressAfterConnection {
            isFirstPressAfterConnection = false
            if buttonName != "siri" {
                return
            }
        }

        // Select mapped to Mouse Click keeps the special click/drag semantics;
        // any other mapping falls through to normal button dispatch below.
        if buttonName == "select",
           (menuBarManager?.getMapping(for: "select") ?? .trackpadClick) == .trackpadClick {
            if trackpadControlEnabled {
                handleSelectButton(pressed: intValue == 1)
            }
            return
        }

        let pressed = (intValue == 1)

        // Debounce only on press — release just closes an existing hold. Symmetric with
        // the AVRCP path: whichever delivery arrives first records the press; the mirror
        // arriving within 200 ms is dropped.
        if pressed {
            if RemoteInputHandler.lastProcessedButton == buttonName,
               RemoteInputHandler.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime) < 0.2 {
                return
            }
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        if buttonName == "siri" {
            if onSiriMic?(pressed) == true {
                return
            }
        }

        var action = menuBarManager?.getMapping(for: buttonName) ?? ButtonAction.none
        if buttonName == "siri", action == .none {
            // Schema v6 removed siri from remappable buttons (reserved for
            // push-to-talk). When dictation didn't consume the press — helper or
            // PacketLogger missing — fall back to the pre-v6 default (Space hold)
            // so the button isn't dead.
            action = .spaceKey
        }
        if pressed {
            print("🔘 Button pressed: \(buttonName) → \(action.rawValue)")
        }
        executeAction(action, button: buttonName, pressed: pressed)
    }
    
    private func handleSelectButton(pressed: Bool) {
        if pressed && !isSelectPressed {
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true
            
            // Start drag after threshold
            DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold) { [weak self] in
                guard let self = self, self.isSelectPressed && !self.isDragging else { return }
                print("🔘 Select button: Drag started")
                self.isDragging = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
            }
        } else if !pressed && isSelectPressed {
            isSelectPressed = false
            
            if isDragging {
                print("🔘 Select button: Drag ended")
                cursorController.isDragging = false
                cursorController.mouseUp()
            } else {
                print("🔘 Select button: Click")
                cursorController.performClick()
            }
            isDragging = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
        }
    }
    
    // MARK: - Button Identification
    
    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)  
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0x42): return "ringUp"        // Click-ring Up
        case (0x0C, 0x43): return "ringDown"      // Click-ring Down
        case (0x0C, 0x44): return "ringLeft"      // Click-ring Left
        case (0x0C, 0x45): return "ringRight"     // Click-ring Right
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE2): return "mute"          // Mute
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    // MARK: - Action Execution
    
    private func executeAction(_ action: ButtonAction, button: String, pressed: Bool) {
        if action.requiresHold {
            if holdCapableButtons.contains(button) {
                handleHoldAction(action, button: button, pressed: pressed)
            } else if action == .backspace, pressed {
                // Press-only buttons (menu/tv/select) can't hold: fire a single tap instead.
                sendKey(kVK_Delete)
            }
            return
        }
        // Tap actions fire once, on press only.
        guard pressed else { return }
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
        case .optionBackspace:
            sendKey(kVK_Delete, flags: .maskAlternate)
        case .commandBackspace:
            sendKey(kVK_Delete, flags: .maskCommand)
        case .ctrlC:
            sendKey(kVK_ANSI_C, flags: .maskControl)
        case .backspace, .spaceKey, .rightCmd, .rightOpt, .f13Key:
            break // handled by handleHoldAction
        case .trackpadClick:
            if trackpadControlEnabled {
                cursorController.performClick()
            }
        case .volumeUp:
            // CoreAudio step + sticky hold against AVRCP. Do not post NX media keys —
            // they re-enter the interceptor and often show a HUD without a lasting change.
            VolumeRevertGuard.shared.applyVolumeStep(1)
        case .volumeDown:
            VolumeRevertGuard.shared.applyVolumeStep(-1)
        case .mute:
            mediaController.sendMediaKey(.mute)
        case .playPause:
            mediaController.sendMediaKey(.playPause)
        }
    }

    /// Press/release a virtual key mirroring the source press duration, with system-like repeat.
    private func handleHoldAction(_ action: ButtonAction, button: String, pressed: Bool) {
        let spec: (keyCode: Int, flags: CGEventFlags)
        switch action {
        case .backspace: spec = (kVK_Delete,       [])
        case .spaceKey: spec = (kVK_Space,        [])
        case .rightCmd: spec = (kVK_RightCommand, .maskCommand)
        case .rightOpt: spec = (kVK_RightOption,  .maskAlternate)
        case .f13Key:   spec = (kVK_F13,          [])
        default: return
        }

        if pressed {
            // Defensive: if a prior release was missed, close the stale hold before opening a new one.
            if let stale = heldKeys.removeValue(forKey: button) {
                releaseHeldKey(stale)
            }
            postKey(keyCode: spec.keyCode, flags: spec.flags, keyDown: true)

            let holdID = UUID()
            let repeatTimer = DispatchSource.makeTimerSource(queue: .main)
            repeatTimer.schedule(
                deadline: .now() + .milliseconds(250),
                repeating: .milliseconds(33),
                leeway: .milliseconds(2)
            )
            repeatTimer.setEventHandler { [weak self] in
                guard let self = self,
                      let held = self.heldKeys[button],
                      held.id == holdID else { return }
                self.postKey(
                    keyCode: held.keyCode,
                    flags: held.flags,
                    keyDown: true,
                    autorepeat: true
                )
            }
            heldKeys[button] = HeldKey(
                id: holdID,
                keyCode: spec.keyCode,
                flags: spec.flags,
                repeatTimer: repeatTimer
            )
            repeatTimer.resume()
        } else {
            guard let held = heldKeys.removeValue(forKey: button) else { return }
            releaseHeldKey(held)
        }
    }

    /// Called on device removal to avoid stuck modifiers if the remote disconnects mid-hold.
    func releaseAllHeldKeys() {
        let activeHolds = Array(heldKeys.values)
        heldKeys.removeAll()
        for held in activeHolds {
            releaseHeldKey(held)
        }
        buttonState.removeAll()
    }

    private func releaseHeldKey(_ held: HeldKey) {
        held.repeatTimer.cancel()
        postKey(keyCode: held.keyCode, flags: [], keyDown: false)
    }

    private func postKey(
        keyCode: Int,
        flags: CGEventFlags,
        keyDown: Bool,
        autorepeat: Bool = false
    ) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        if autorepeat {
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        postKey(keyCode: keyCode, flags: flags, keyDown: true)
        usleep(10000)
        postKey(keyCode: keyCode, flags: flags, keyDown: false)
    }
}

// C callback
private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}
