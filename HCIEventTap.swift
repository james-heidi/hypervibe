//
//  HCIEventTap.swift
//  HyperVibe
//
//  Subscribe to IOBluetoothHostController HCI event notifications without PacketLogger.
//  Observes command/event traffic. ACL ATT voice frames are not delivered here on
//  current macOS (see DurableCaptureSpike / docs/spike-durable-capture.md).
//

import Foundation
import IOBluetooth

/// Lightweight HCI event observer via private `IOBluetoothHostControllerDelegate`.
final class HCIEventTap: NSObject {
    private var controller: IOBluetoothHostController?
    private(set) var eventCount = 0
    /// Hex dump of the first bytes (legacy).
    var onRawHex: ((String) -> Void)?
    /// Raw notification bytes (best-effort sized buffer for Spike A signature scan).
    var onRawBytes: ((Data) -> Void)?

    /// How many bytes to copy from the opaque notification pointer.
    /// Oversized relative to typical HCI events so Spike A can search for Opus TOC.
    private let dumpLength = 512

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
        let bytes = UnsafeRawBufferPointer(start: message, count: dumpLength)
        let data = Data(bytes)
        let hex = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        if eventCount <= 20 || eventCount % 50 == 0 {
            rmDebug("🎤 HCI event #\(eventCount): \(hex)")
        }
        onRawHex?(hex)
        onRawBytes?(data)
    }
}
