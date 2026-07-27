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
final class MicActivator {
    static let inputEnableByte: UInt8 = 0xAF
    private var openDevices: [IOHIDDevice] = []
    private var ownsDevices = false

    /// Prefer devices already seized by `RemoteInputHandler` so SetReport is not
    /// rejected with `kIOReturnExclusiveAccess`.
    ///
    /// Does **not** toggle PushToTalk off first — HID reattach during an active
    /// hold used to call `disarm()` and cut the mic stream mid-utterance.
    func useSharedDevices(_ devices: [IOHIDDevice]) {
        if ownsDevices {
            for device in openDevices {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }
        openDevices = devices
        ownsDevices = false
        rmDebug("🎤 MicActivator using \(devices.count) shared HID device(s)")
        sendEnable()
        tryPushToTalk(enabled: true)
    }

    /// Open every Apple remote-looking HID device and keep them for SetReport.
    func arm() {
        disarm()
        ownsDevices = true
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
            // Apple vendor; A2854 product 0x0315 (789). Also accept other Siri remotes.
            let isApple = vendor == 0x004C || vendor == 1452
            let isRemote = product == 0x0315 || product == 0x0266 || product == 789 || product == 614
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
        sendEnable()
        tryPushToTalk(enabled: true)
    }

    func disarm() {
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
        var logged = Set<String>()
        for device in openDevices {
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
                    rmDebug(String(
                        format: "🎤 MicActivator OUTPUT id=0x%02x [AF] ok",
                        reportID
                    ))
                }
            }
        }
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
