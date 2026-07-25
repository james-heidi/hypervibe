//
//  HCIEventTap.swift
//  HyperVibe
//
//  Subscribe to IOBluetoothHostController HCI event notifications without PacketLogger.
//  This observes command/event traffic; ACL ATT voice frames still typically require
//  PacketLogger, but the tap is useful for spotting activation writes and for machines
//  where the logging profile is unavailable.
//

import Foundation
import IOBluetooth

/// Lightweight HCI event observer via private `IOBluetoothHostControllerDelegate`.
final class HCIEventTap: NSObject {
    private var controller: IOBluetoothHostController?
    private(set) var eventCount = 0
    var onRawHex: ((String) -> Void)?

    func start() {
        let c = IOBluetoothHostController.default()
        controller = c
        c?.delegate = self
        rmDebug("🎤 HCIEventTap started controller=\(c != nil)")
    }

    func stop() {
        controller?.delegate = nil
        controller = nil
        rmDebug("🎤 HCIEventTap stopped events=\(eventCount)")
    }
}

extension HCIEventTap: IOBluetoothHostControllerDelegate {
    // Selector matching InternalBlue / class-dump spelling.
    @objc(BluetoothHCIEventNotificationMessage:inNotificationMessage:)
    func bluetoothHCIEventNotificationMessage(
        _ controller: IOBluetoothHostController!,
        inNotificationMessage message: UnsafeMutableRawPointer!
    ) {
        guard message != nil else { return }
        eventCount += 1
        // Best-effort dump of the first bytes of the opaque notification.
        let bytes = UnsafeRawBufferPointer(start: message, count: 64)
        let hex = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        if eventCount <= 20 || eventCount % 50 == 0 {
            rmDebug("🎤 HCI event #\(eventCount): \(hex)")
        }
        onRawHex?(hex)
    }
}
