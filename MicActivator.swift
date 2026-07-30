//
//  MicActivator.swift
//  HyperVibe
//
//  Attempt to host-activate the A2854 microphone stream over IOHID.
//  Linux uses GATT write 0xAF + CCCD; macOS rewrites report IDs, so this
//  probes every Feature surface and the driver's PushToTalk property.
//

import Foundation
import IOKit.hid

/// Arms gen-3 voice streaming while Siri is held.
///
/// Every public entry point hops onto `queue` and returns immediately. `sendEnable`
/// replays up to 20 `IOHIDDeviceSetReport` round trips at ~60 ms each — measured at
/// 1.2 s — which used to run on the Siri-down callback and froze the main runloop
/// (and with it the dictation wave) for the whole press. The serial queue keeps the
/// enable→disable ordering that the press path depends on: a release's `disarm()`
/// cannot overtake its own press's arm, so the microphone is never left armed.
final class MicActivator {
    static let inputEnableByte: UInt8 = 0xAF
    private let queue = DispatchQueue(label: "com.hypervibe.mic-activator")
    private var openDevices: [IOHIDDevice] = []
    private var ownsDevices = false

    /// A (device, report type, report ID) triple that accepted the enable byte.
    private struct ReportTarget {
        let deviceIndex: Int
        let reportType: IOHIDReportType
        let reportID: UInt8
    }

    /// Discovery pokes every report surface, but only a couple ever answer. Each
    /// rejected `SetReport` still costs a synchronous round trip to the remote, so
    /// replaying only the proven ones keeps Siri-down off the critical path.
    private var provenTargets: [ReportTarget] = []

    /// Prefer devices already seized by `RemoteInputHandler` so SetReport is not
    /// rejected with `kIOReturnExclusiveAccess`.
    ///
    /// Does **not** toggle PushToTalk off first — HID reattach during an active
    /// hold used to call `disarm()` and cut the mic stream mid-utterance.
    func useSharedDevices(_ devices: [IOHIDDevice]) {
        queue.async { self.useSharedDevicesOnQueue(devices) }
    }

    private func useSharedDevicesOnQueue(_ devices: [IOHIDDevice]) {
        if ownsDevices {
            for device in openDevices {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }
        openDevices = devices
        ownsDevices = false
        provenTargets.removeAll()
        rmDebug("🎤 MicActivator using \(devices.count) shared HID device(s)")
        // Device attachment is not a Siri hold. Only `rearmOnSiriDown()` should
        // write reports / toggle PushToTalk; doing it here caused startup storms
        // while bluetoothd re-enumerated the remote's HID interfaces.
    }

    /// Open every Apple remote-looking HID device and keep them for SetReport.
    func arm() {
        queue.async { self.armOnQueue() }
    }

    private func armOnQueue() {
        // Never call disarm() here — that would leave shared devices in openDevices
        // then mark ownsDevices=true and close RemoteInputHandler's seize on teardown.
        if ownsDevices {
            for device in openDevices {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }
        openDevices.removeAll()
        provenTargets.removeAll()
        ownsDevices = true
        tryPushToTalk(enabled: false)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            rmDebug("🎤 MicActivator: no HID devices")
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return
        }

        for device in set {
            let vendor = intProperty(device, kIOHIDVendorIDKey) ?? 0
            let product = intProperty(device, kIOHIDProductIDKey) ?? 0
            // Apple vendor; product IDs come from RemoteAdapterRegistry.
            let isApple = vendor == 0x004C || vendor == 1452
            let isRemote = RemoteAdapterRegistry.allKnownProductIDs.contains(product)
            guard isApple && (isRemote || productName(device).localizedCaseInsensitiveContains("remote")) else {
                continue
            }
            // Seize so we can write Features even if another client briefly held them.
            let opts = IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            let kr = IOHIDDeviceOpen(device, opts)
            if kr == kIOReturnSuccess {
                openDevices.append(device)
                rmDebug("🎤 MicActivator seized product=0x\(String(product, radix: 16)) \(productName(device))")
            } else {
                rmDebug(String(
                    format: "🎤 MicActivator open failed product=0x%x -> 0x%08x",
                    product,
                    UInt32(bitPattern: Int32(kr))
                ))
            }
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        sendEnable()
        tryPushToTalk(enabled: true)
    }

    func rearmOnSiriDown() {
        queue.async {
            let began = CFAbsoluteTimeGetCurrent()
            self.sendEnable()
            self.tryPushToTalk(enabled: true)
            rmDebug(String(
                format: "🎤 MicActivator rearm total %.0fms",
                (CFAbsoluteTimeGetCurrent() - began) * 1000
            ))
        }
    }

    func disarm() {
        queue.async { self.disarmOnQueue() }
    }

    /// Teardown variant for app shutdown: waits so the process cannot exit before
    /// `PushToTalk(false)` reaches the remote and leave its microphone armed.
    func disarmAndWait() {
        queue.sync { self.disarmOnQueue() }
    }

    private func disarmOnQueue() {
        tryPushToTalk(enabled: false)
        if ownsDevices {
            for device in openDevices {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            openDevices.removeAll()
            ownsDevices = false
        }
        // Shared devices (from RemoteInputHandler seize) must stay retained —
        // clearing them made every rearm after the first Siri release a no-op.
    }

    private func sendEnable() {
        var byte = Self.inputEnableByte
        let began = CFAbsoluteTimeGetCurrent()

        if !provenTargets.isEmpty {
            for target in provenTargets where target.deviceIndex < openDevices.count {
                _ = IOHIDDeviceSetReport(
                    openDevices[target.deviceIndex],
                    target.reportType,
                    CFIndex(target.reportID),
                    &byte,
                    1
                )
            }
            rmDebug(String(
                format: "🎤 MicActivator enable replay targets=%d in %.0fms",
                provenTargets.count,
                (CFAbsoluteTimeGetCurrent() - began) * 1000
            ))
            return
        }

        var logged = Set<String>()
        var discovered: [ReportTarget] = []
        for (index, device) in openDevices.enumerated() {
            // Feature report ID 0xFF is what macOS exposes for the large remote reports.
            // Also poke 0x00 / 0xF1 / 0xFA / 0xAF in case of alternate mappings.
            for reportID in [0xFF, 0xF1, 0xFA, 0xAF, 0x00] as [UInt8] {
                let kr = IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    CFIndex(reportID),
                    &byte,
                    1
                )
                if kr == kIOReturnSuccess {
                    discovered.append(ReportTarget(
                        deviceIndex: index,
                        reportType: kIOHIDReportTypeFeature,
                        reportID: reportID
                    ))
                }
                let key = String(format: "F:%02x:%08x", reportID, UInt32(bitPattern: Int32(kr)))
                if logged.insert(key).inserted {
                    rmDebug(String(
                        format: "🎤 MicActivator FEATURE id=0x%02x [AF] -> 0x%08x",
                        reportID,
                        UInt32(bitPattern: Int32(kr))
                    ))
                }
                // Output reports (Linux path). Expected to fail on many interfaces.
                let krOut = IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    CFIndex(reportID),
                    &byte,
                    1
                )
                if krOut == kIOReturnSuccess {
                    discovered.append(ReportTarget(
                        deviceIndex: index,
                        reportType: kIOHIDReportTypeOutput,
                        reportID: reportID
                    ))
                    rmDebug(String(
                        format: "🎤 MicActivator OUTPUT id=0x%02x [AF] ok",
                        reportID
                    ))
                }
            }
        }
        provenTargets = discovered
        rmDebug(String(
            format: "🎤 MicActivator enable discovery kept=%d/%d in %.0fms",
            discovered.count,
            openDevices.count * 10,
            (CFAbsoluteTimeGetCurrent() - began) * 1000
        ))
    }

    /// Exercise AppleBluetoothRemote's PushToTalk IOKit property when present.
    private func tryPushToTalk(enabled: Bool) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleEmbeddedBluetoothDeviceManagement")
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        let kr = IOServiceGetMatchingServices(mainPort, matching, &iterator)
        guard kr == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            // Prefer registry property write via IORegistryEntrySetCFProperty.
            let value = NSNumber(value: enabled ? 1 : 0)
            let setKr = IORegistryEntrySetCFProperty(service, "PushToTalk" as CFString, value)
            rmDebug("🎤 PushToTalk set(\(enabled)) -> 0x\(String(setKr, radix: 16))")
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func productName(_ device: IOHIDDevice) -> String {
        (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
    }
}
