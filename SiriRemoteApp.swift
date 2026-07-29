//
//  SiriRemoteApp.swift
//  HyperVibe
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    private var remoteMicController: RemoteMicController?
    private var micWakeObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 HyperVibe starting...")

        // Bluetooth AVRCP play/pause signals bypass cghidEventTap and reach com.apple.rcd
        // directly, which launches Music.app. Suspend rcd for this session; restored on exit.
        RCDControl.suspend()

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager(statusItem: statusItem)
        menuBarManager.mediaController = MediaController()
        
        // Initialize controllers
        let cursorController = CursorController()

        let inputHandler = RemoteInputHandler(
            cursorController: cursorController,
            menuBarManager: menuBarManager
        )
        inputHandler.setTrackpadControlEnabled(menuBarManager.trackpadControlEnabled)
        remoteInputHandler = inputHandler
        
        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        let touchInputHandler = TouchHandler(cursorController: cursorController)
        touchHandler = touchInputHandler
        touchInputHandler.scrollScale = menuBarManager.scrollSpeed.scale
        touchInputHandler.setTrackpadControlEnabled(menuBarManager.trackpadControlEnabled)
        menuBarManager.onTrackpadControlToggle = { [weak inputHandler, weak touchInputHandler] enabled in
            inputHandler?.setTrackpadControlEnabled(enabled)
            touchInputHandler?.setTrackpadControlEnabled(enabled)
        }
        touchInputHandler.start()
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
            self?.remoteMicController?.ensureCaptureWarm()
        }

        // A2854 remote mic → PacketLogger HCI → Opus → selectable transcription engine.
        // Dictation is always on (no menu toggle); helper install remains a one-shot prompt.
        let mic = RemoteMicController()
        remoteMicController = mic
        let ensureDictation: () -> Void = { [weak self, weak mic] in
            // Helper ping + system_profiler can block for seconds — never on main.
            DispatchQueue.global(qos: .userInitiated).async {
                let helperReady = HCIHelperClient.isReady()
                let labReady = helperReady && RemoteMicLab.evaluate().isReady
                DispatchQueue.main.async {
                    guard let self, let mic else { return }
                    guard labReady else {
                        // Prerequisites missing (helper/PacketLogger/profile) —
                        // disable so handleSiri returns false and Siri presses
                        // fall through to HID mapping instead of being consumed.
                        mic.setEnabled(false)
                        return
                    }
                    mic.setEnabled(true)
                    mic.attachSeizedDevices(self.remoteInputHandler?.seizedDevices ?? [])
                    mic.startIdleCaptureIfEnabled()
                }
            }
        }
        menuBarManager.onEnsureDictationEnabled = ensureDictation
        menuBarManager.onTranscriptionEngineChange = { [weak mic] id in
            mic?.setEngine(id)
        }
        menuBarManager.onOpenAIKeySave = { [weak self, weak mic] key in
            do {
                try TranscriptionKeychain.saveOpenAIKey(key)
                mic?.prepareSelectedEngine(completion: nil)
                if let mic {
                    self?.menuBarManager.updatePolishStatus(
                        mode: mic.polishMode,
                        localSummary: mic.polishLocalSummary,
                        cloudSummary: mic.polishCloudSummary
                    )
                }
            } catch {
                let alert = NSAlert.hyperVibeAlert()
                alert.messageText = "无法保存 OpenAI Key"
                alert.informativeText = error.localizedDescription
                alert.runHyperVibeModal()
            }
        }
        menuBarManager.onParakeetDownload = { [weak mic] in
            mic?.setEngine(.parakeet)
            mic?.startParakeetDownload(completion: nil)
        }
        menuBarManager.onParakeetDownloadCancel = { [weak mic] in
            mic?.cancelParakeetDownload()
        }
        menuBarManager.onPolishModeChange = { [weak mic, weak menuBarManager] mode in
            mic?.polishMode = mode
            if let mic {
                menuBarManager?.updatePolishStatus(
                    mode: mode,
                    localSummary: mic.polishLocalSummary,
                    cloudSummary: mic.polishCloudSummary
                )
            }
        }
        // Off until ensureDictation confirms lab readiness (async, below).
        menuBarManager.selectedTranscriptionEngine = mic.engineID
        menuBarManager.transcriptionEngineStatus = mic.engineState
        menuBarManager.updatePolishStatus(
            mode: mic.polishMode,
            localSummary: mic.polishLocalSummary,
            cloudSummary: mic.polishCloudSummary
        )
        mic.prewarmPolish()
        mic.onReadinessState = { [weak menuBarManager] state in
            menuBarManager?.updateMicReadiness(state)
        }
        mic.onAudioLevel = { [weak menuBarManager] level in
            menuBarManager?.updateMicAudioLevel(level)
        }
        mic.onEngineState = { [weak menuBarManager] id, state in
            menuBarManager?.updateTranscriptionEngine(id: id, state: state)
        }
        mic.onTranscribedText = { [weak menuBarManager] text in
            menuBarManager?.typeDictationText(text)
        }
        menuBarManager.onRecoveryAction = { [weak mic] in
            mic?.performRecovery()
        }
        menuBarManager.onOpenSetupWizard = { [weak self] in
            self?.presentOnboarding()
        }
        HelperInstallCoordinator.shared.addOnChange(id: "app") { [weak self] in
            SetupCoordinator.shared.refresh(reason: .helper)
            self?.menuBarManager.requestMenuRebuild()
            // Warm capture when the daemon answers — not on every UI tick.
            if HelperInstallCoordinator.shared.readiness.isUsableForCapture {
                self?.menuBarManager.onEnsureDictationEnabled?()
            }
        }
        SetupCoordinator.shared.onInputMonitoringGranted = { [weak self] in
            self?.restartMediaKeyInterceptor()
        }
        inputHandler.onSiriMic = { [weak mic] pressed in
            mic?.handleSiri(pressed: pressed) ?? false
        }
        ensureDictation()
        // Warm capture starts from ensureDictation once helper readiness is known off-main.
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                self?.remoteInputHandler?.setRemoteDevice(device)
                self?.menuBarManager.updateConnectionStatus(connected: device != nil)
                if let devices = self?.remoteInputHandler?.seizedDevices {
                    self?.remoteMicController?.attachSeizedDevices(devices)
                }
                if device != nil {
                    // Remote may connect after launch; warm capture immediately instead
                    // of waiting for the first Siri press.
                    ensureDictation()
                    self?.remoteMicController?.ensureCaptureWarm()
                } else {
                    // Release any held push-to-talk — a disconnect mid-press means the
                    // Siri key-up will never arrive.
                    self?.remoteMicController?.remoteDidDisconnect()
                }
            }
        }
        remoteDetector?.startDetection()
        menuBarManager.requestMenuRebuild()

        micWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak mic] _ in
            mic?.ensureCaptureWarm()
        }
        
        // Start media key interceptor (Input Monitoring may still be missing —
        // onboarding / 安装 menu will request it and restart the tap).
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()

        ModelDownloadMirror.applyToRegistry()
        HelperInstallCoordinator.shared.refresh(reason: "launch")
        // Keychain reads can stall behind a SecurityAgent prompt — resolve the
        // OpenAI key off-main and repaint once known.
        TranscriptionKeychain.refreshOpenAIKeyPresence { [weak self] changed in
            guard changed, let self, let mic = self.remoteMicController else { return }
            self.menuBarManager.updatePolishStatus(
                mode: mic.polishMode,
                localSummary: mic.polishLocalSummary,
                cloudSummary: mic.polishCloudSummary
            )
        }

        // Present onboarding after the status item and pipelines are wired.
        DispatchQueue.main.async { [weak self] in
            SetupCoordinator.shared.refresh(reason: .launch)
            if SetupCoordinator.shouldPresentOnLaunch() {
                self?.presentOnboarding()
            }
        }
    }

    private var onboardingController: OnboardingWindowController?

    private func presentOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController()
        }
        onboardingController?.present()
    }

    private func restartMediaKeyInterceptor() {
        mediaKeyInterceptor?.stop()
        mediaKeyInterceptor?.start()
        if !HyperVibePermission.inputMonitoring.isGranted {
            return
        }
        // If the tap still won't arm, ask for a relaunch.
        // MediaKeyInterceptor logs failure; a second start after grant usually works.
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        if let observer = micWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            micWakeObserver = nil
        }
        remoteMicController?.clearRecovery()
        remoteMicController?.shutdown()
        remoteInputHandler?.releaseAllHeldKeys()
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        RCDControl.restore()
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let buttonName: String
        switch keyType {
        case .playPause:  buttonName = "playPause"
        case .next:       buttonName = "nextTrack"
        case .previous:   buttonName = "prevTrack"
        case .volumeUp:   buttonName = "volumeUp"
        case .volumeDown: buttonName = "volumeDown"
        case .mute:       buttonName = "mute"
        }

        let action = menuBarManager.getMapping(for: buttonName)

        // Native volume/mute/playPause: HID already applied (or will apply) the real
        // action. Always consume the system media key so we don't get a HUD-only
        // NX event fighting AVRCP absolute-volume.
        if let native = ButtonAction.nativeMediaAction(forButton: buttonName), action == native {
            if RemoteInputHandler.lastProcessedButton == buttonName {
                let timeSinceLastProcess = Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime)
                if timeSinceLastProcess < 0.2 {
                    return true
                }
            }
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
            menuBarManager.executeAction(action.rawValue)
            return true
        }

        // Debounce: if the HID path just handled this button, don't double-fire.
        if RemoteInputHandler.lastProcessedButton == buttonName {
            let timeSinceLastProcess = Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime)
            if timeSinceLastProcess < 0.2 {
                return true
            }
        }

        if action != .none {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
            menuBarManager.executeAction(action.rawValue)
        }
        // Always consume remapped media keys — default macOS handler must not fire.
        return true
    }
}

/// Suspends `com.apple.rcd` (Remote Control Daemon) for the user's GUI launchd domain while
/// HyperVibe is running. rcd is what reacts to Bluetooth AVRCP play signals by launching
/// Music.app — a channel that bypasses HID seize and the cghidEventTap entirely. `bootout`
/// only affects this login session; restored on clean exit, and on next login either way.
enum RCDControl {
    private static let plistPath = "/System/Library/LaunchAgents/com.apple.rcd.plist"
    private static var suspended = false

    static func suspend() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/com.apple.rcd"
        guard isLoaded(service: service) else {
            print("ℹ️ com.apple.rcd not loaded; skipping suspend")
            return
        }
        let (status, err) = run(["bootout", service])
        if status == 0 {
            suspended = true
            print("🔇 com.apple.rcd suspended (Music won't auto-launch from BT remote)")
        } else {
            print("⚠️ Could not suspend com.apple.rcd (launchctl exit=\(status)): \(err)")
        }
    }

    static func restore() {
        guard suspended else { return }
        let domain = "gui/\(getuid())"
        let (status, err) = run(["bootstrap", domain, plistPath])
        if status == 0 {
            print("🔊 com.apple.rcd restored")
        } else {
            print("⚠️ Could not restore com.apple.rcd (launchctl exit=\(status)): \(err) — next login will re-register it")
        }
        suspended = false
    }

    private static func isLoaded(service: String) -> Bool {
        let (status, _) = run(["print", service], captureStderr: false)
        return status == 0
    }

    private static func run(_ args: [String], captureStderr: Bool = true) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = captureStderr ? errPipe : Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let errData = captureStderr ? errPipe.fileHandleForReading.readDataToEndOfFile() : Data()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, errStr)
        } catch {
            return (-1, "\(error)")
        }
    }
}
