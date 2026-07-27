//
//  SystemVolume.swift
//  HyperVibe
//
//  CoreAudio volume read/write + a listener-based revert guard that reverses
//  AVRCP-origin volume changes during a short window after a remote volume HID press.
//

import AudioToolbox
import CoreAudio
import Foundation

enum SystemVolume {
    static func get() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    static func set(_ volume: Float) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        var v = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &v)

        // Some devices ignore VirtualMainVolume and only honor per-channel scalars.
        for element: UInt32 in 1...2 {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var ch = v
            AudioObjectSetPropertyData(deviceID, &chAddr, 0, nil, size, &ch)
        }
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (status == noErr && id != 0) ? id : nil
    }
}

/// Reverts AVRCP-origin volume changes caused by the Siri Remote's volume buttons.
///
/// The Siri Remote also sends BT AVRCP absolute-volume. That path writes below our
/// event taps and will snap the Mac back to the remote's notion of level unless we
/// actively hold our target for a while after each intentional step.
final class VolumeRevertGuard {
    static let shared = VolumeRevertGuard()

    /// One keyboard volume step ≈ 1/16 of full scale on macOS.
    private static let stepSize: Float = 1.0 / 16.0

    private var baselineVolume: Float?
    private var guardUntil: Date = .distantPast
    private let guardWindow: TimeInterval = 0.5
    private let settleDelay: TimeInterval = 0.15
    private var pendingSettle: DispatchWorkItem?
    private var listenerInstalled = false
    private var listenerDeviceID: AudioObjectID = 0
    /// Skip revert while we intentionally write volume (our own set echoes to the listener).
    private var ignoringListener = false

    /// After a native volume step, keep re-asserting this level against AVRCP snaps.
    private var stickyTarget: Float?
    private var stickyUntil: Date = .distantPast
    private var stickyTimer: DispatchSourceTimer?
    private let stickyHold: TimeInterval = 2.0

    /// Install the CoreAudio listener and capture the starting baseline at app launch,
    /// so the first remote volume press has something to revert to.
    func prewarm() {
        ensureListener()
        if baselineVolume == nil {
            baselineVolume = SystemVolume.get()
        }
        rmDebug("🔊 VolumeRevertGuard prewarm: listener=\(listenerInstalled) baseline=\(baselineVolume.map { String(format: "%.3f", $0) } ?? "nil")")
    }

    /// Called on every volume HID press from the remote. Opens the guard window and, if a
    /// volume change landed in the last `settleDelay` ms, reverts it retroactively — this
    /// handles the common case where AVRCP beats HID to the main thread.
    func armFromRemoteButton() {
        ensureListener()
        guardUntil = Date().addingTimeInterval(guardWindow)
        if pendingSettle != nil, let baselineValue = baselineVolume {
            pendingSettle?.cancel()
            pendingSettle = nil
            writeVolume(baselineValue)
        }
    }

    /// Apply a real CoreAudio volume step and hold it against AVRCP absolute-volume snaps.
    func applyVolumeStep(_ steps: Int) {
        ensureListener()
        pendingSettle?.cancel()
        pendingSettle = nil

        // Prefer the live level so we don't step from a stale baseline after an AVRCP fight.
        let actual = SystemVolume.get() ?? baselineVolume ?? 0.5
        let next = max(0, min(1, actual + Float(steps) * Self.stepSize))
        baselineVolume = next
        stickyTarget = next
        stickyUntil = Date().addingTimeInterval(stickyHold)
        guardUntil = stickyUntil

        writeVolume(next)
        startStickyHold(target: next)
        rmDebug("🔊 applyVolumeStep \(steps): \(String(format: "%.3f", actual)) → \(String(format: "%.3f", next))")
    }

    private func startStickyHold(target: Float) {
        stickyTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Hammer the target for stickyHold — AVRCP absolute packets arrive for ~1s+.
        timer.schedule(deadline: .now() + 0.03, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard Date() < self.stickyUntil else {
                self.stickyTimer?.cancel()
                self.stickyTimer = nil
                self.stickyTarget = nil
                // Re-sync baseline to whatever actually stuck.
                self.baselineVolume = SystemVolume.get() ?? target
                rmDebug("🔊 sticky hold ended; baseline=\(self.baselineVolume.map { String(format: "%.3f", $0) } ?? "nil")")
                return
            }
            if let current = SystemVolume.get(), abs(current - target) > 0.001 {
                rmDebug("🔊 sticky reassert \(String(format: "%.3f", current)) → \(String(format: "%.3f", target))")
                self.writeVolume(target)
            }
        }
        stickyTimer = timer
        timer.resume()
    }

    private func writeVolume(_ volume: Float) {
        ignoringListener = true
        SystemVolume.set(volume)
        ignoringListener = false
    }

    private func ensureListener() {
        guard !listenerInstalled, let id = SystemVolume.defaultOutputDeviceID() else { return }
        listenerDeviceID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.onVolumeChanged()
        }
        if status == noErr {
            listenerInstalled = true
        }
    }

    private func onVolumeChanged() {
        if ignoringListener { return }
        guard let current = SystemVolume.get() else {
            rmDebug("🔊 listener fired but SystemVolume.get() returned nil")
            return
        }

        // Native volume sticky hold owns the level; don't run the remapped-button revert path.
        if let target = stickyTarget, Date() < stickyUntil {
            if abs(current - target) > 0.001 {
                rmDebug("🔊 sticky listener reassert \(String(format: "%.3f", current)) → \(String(format: "%.3f", target))")
                writeVolume(target)
            }
            return
        }

        let baselineStr = baselineVolume.map { String(format: "%.3f", $0) } ?? "nil"
        let inWindow = Date() < guardUntil
        rmDebug("🔊 listener: current=\(String(format: "%.3f", current)) baseline=\(baselineStr) inGuard=\(inWindow)")

        if let baseline = baselineVolume, abs(current - baseline) < 0.001 {
            rmDebug("🔊 listener: match baseline, noop")
            return
        }

        if inWindow, let baseline = baselineVolume {
            rmDebug("🔊 listener: reverting \(String(format: "%.3f", current)) → \(String(format: "%.3f", baseline))")
            writeVolume(baseline)
            return
        }
        // Outside guard: defer committing this as the new baseline. If a remote HID press
        // arrives within settleDelay, it retroactively reverts instead.
        let captured = current
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.baselineVolume = captured
            self?.pendingSettle = nil
            rmDebug("🔊 settle: baseline committed = \(String(format: "%.3f", captured))")
        }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }
}
