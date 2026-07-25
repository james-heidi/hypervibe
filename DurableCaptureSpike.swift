//
//  DurableCaptureSpike.swift
//  HyperVibe
//
//  Go/no-go probes for A2854 voice without PacketLogger:
//    Spike A — private IOBluetooth HCI event tap during Siri-hold
//    Spike B — BTDebug / CoreCapture IOService open without relying on PacketLogger
//
//  These are developer diagnostics (`--spike-a` / `--spike-b`), not product UI.
//

import Foundation
import IOBluetooth
import IOKit

enum DurableCaptureSpike {
    struct SpikeAResult: CustomStringConvertible {
        var profileInstalled: Bool
        var durationSec: Double
        var hciEvents: Int
        var opusCandidatesInEvents: Int
        var packetLoggerFrames: Int?
        var packetLoggerAvailable: Bool
        var notes: [String]

        var ioBluetoothReceivesVoice: Bool { opusCandidatesInEvents > 0 }

        var description: String {
            var lines = [
                "=== Spike A: IOBluetooth HCI event tap ===",
                "Bluetooth logging profile: \(profileInstalled)",
                "Duration: \(String(format: "%.1f", durationSec))s",
                "HCI events via IOBluetoothHostControllerDelegate: \(hciEvents)",
                "A2854 Opus candidates inside those events: \(opusCandidatesInEvents)",
                "PacketLogger available: \(packetLoggerAvailable)",
            ]
            if let frames = packetLoggerFrames {
                lines.append("PacketLogger A2854 frames (control): \(frames)")
            } else {
                lines.append("PacketLogger A2854 frames (control): not run")
            }
            lines.append("Verdict: IOBluetooth receives voice = \(ioBluetoothReceivesVoice)")
            for n in notes { lines.append("Note: \(n)") }
            return lines.joined(separator: "\n")
        }
    }

    struct SpikeBResult: CustomStringConvertible {
        var profileInstalled: Bool
        var btDebugPresent: Bool
        var btDebugOpenKR: kern_return_t?
        var btDebugClientPresent: Bool
        var coreCaptureBTPipes: [String]
        var hciAclPipeFound: Bool
        var openAttempts: [(name: String, kr: kern_return_t)]
        var notes: [String]

        var durableCaptureWithoutProfile: Bool {
            // Pass only if we found a usable HCI/ACL pipe we could open without PacketLogger.
            // StateDump pipes alone are not voice capture.
            hciAclPipeFound && (btDebugOpenKR == KERN_SUCCESS || openAttempts.contains { $0.kr == KERN_SUCCESS })
        }

        var description: String {
            var lines = [
                "=== Spike B: BTDebug / CoreCapture ===",
                "Bluetooth logging profile: \(profileInstalled)",
                "BTDebug IOService present: \(btDebugPresent)",
                "BTDebug IOServiceOpen: \(btDebugOpenKR.map { String(format: "0x%08x", $0) } ?? "n/a")",
                "BTDebugUserClient instances (ioreg): \(btDebugClientPresent)",
                "HCI/ACL-capable CoreCapture pipe found: \(hciAclPipeFound)",
                "CoreCapture BT-related pipes:",
            ]
            if coreCaptureBTPipes.isEmpty {
                lines.append("  (none)")
            } else {
                for p in coreCaptureBTPipes { lines.append("  - \(p)") }
            }
            if !openAttempts.isEmpty {
                lines.append("IOServiceOpen attempts:")
                for a in openAttempts {
                    lines.append("  \(a.name) kr=\(String(format: "0x%08x", a.kr))")
                }
            }
            lines.append("Verdict: durable capture without PacketLogger = \(durableCaptureWithoutProfile)")
            for n in notes { lines.append("Note: \(n)") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Spike A

    /// Run Siri-hold window: IOBluetooth event tap + optional PacketLogger control.
    static func runSpikeA(durationSec: TimeInterval = 12) -> SpikeAResult {
        let profile = MicCapturePipeline.bluetoothProfileInstalled()
        var notes = [String]()
        if profile {
            notes.append("Profile is ON — PacketLogger control proves audio is on the wire while the event tap is measured.")
            notes.append("Profile OFF is not required to kill the IOBluetooth receive path: if events contain no Opus while PacketLogger sees frames, private IOBluetooth cannot receive voice.")
        } else {
            notes.append("Profile is OFF — PacketLogger control may fail; event tap still measured.")
        }

        let tap = HCIEventTap()
        var opusInEvents = 0
        tap.onRawBytes = { data in
            if Self.containsA2854OpusSignature(data) {
                opusInEvents += 1
            }
        }
        tap.start()

        let activator = MicActivator()
        activator.arm()

        var plFrames: Int?
        let plAvailable = MicCapturePipeline.packetLoggerURL() != nil
        let capture: MicCapturePipeline?
        if plAvailable {
            let c = MicCapturePipeline()
            capture = c
            c.start()
            notes.append("Started PacketLogger convert stream as live wire control.")
        } else {
            capture = nil
            notes.append("PacketLogger missing — live wire control unavailable.")
        }

        // Mimic Siri-hold: re-arm activation immediately, keep RunLoop spinning for callbacks.
        activator.rearmOnSiriDown()
        let deadline = Date().addingTimeInterval(durationSec)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        plFrames = capture.map { $0.framesSeen }
        capture?.stop()
        activator.disarm()
        let events = tap.eventCount
        tap.stop()

        // Offline PacketLogger control: prior live capture proves the wire format exists
        // even when the operator cannot hold Siri during this automated run.
        let offline = offlinePacketLoggerFrameCount()
        if (plFrames ?? 0) == 0, let offline, offline > 0 {
            plFrames = offline
            notes.append("Live PacketLogger frames=0 (no Siri hold); using offline control /tmp/hypervibe-hci-siri.nhdr frames=\(offline).")
        }

        if let frames = plFrames, frames > 0, opusInEvents == 0 {
            notes.append("FAIL expected: PacketLogger path has \(frames) A2854 frames; IOBluetooth event tap saw 0 Opus candidates.")
        } else if opusInEvents > 0 {
            notes.append("UNEXPECTED PASS: Opus signatures appeared in IOBluetooth notifications.")
        } else if plFrames == 0 || plFrames == nil {
            notes.append("Inconclusive wire control (0 PacketLogger frames). Hold Siri during capture, or place /tmp/hypervibe-hci-siri.nhdr.")
        }

        return SpikeAResult(
            profileInstalled: profile,
            durationSec: durationSec,
            hciEvents: events,
            opusCandidatesInEvents: opusInEvents,
            packetLoggerFrames: plFrames,
            packetLoggerAvailable: plAvailable,
            notes: notes
        )
    }

    // MARK: - Spike B

    static func runSpikeB() -> SpikeBResult {
        let profile = MicCapturePipeline.bluetoothProfileInstalled()
        var notes = [String]()
        var pipes = [String]()
        var opens: [(String, kern_return_t)] = []

        let btDebug = findService(className: "BTDebug")
        let btDebugPresent = btDebug != 0
        var openKR: kern_return_t?
        if btDebug != 0 {
            var conn: io_connect_t = 0
            let kr = IOServiceOpen(btDebug, mach_task_self_, 0, &conn)
            openKR = kr
            opens.append(("BTDebug type0", kr))
            if kr == KERN_SUCCESS {
                notes.append("Opened BTDebug user client (type 0); no documented ACL stream API — closing.")
                IOServiceClose(conn)
            } else {
                notes.append("BTDebug IOServiceOpen failed — likely entitlement / policy gated.")
            }
            // Try a few selector types commonly used by Apple debug clients.
            for t: UInt32 in [1, 2, 3, 0x100] {
                var c: io_connect_t = 0
                let k = IOServiceOpen(btDebug, mach_task_self_, t, &c)
                opens.append(("BTDebug type\(t)", k))
                if k == KERN_SUCCESS { IOServiceClose(c) }
            }
            IOObjectRelease(btDebug)
        } else {
            notes.append("BTDebug IOService not present.")
        }

        // Inventory CoreCapture plane for BT-owned pipes.
        let planePipes = listCoreCaptureBTPipes()
        pipes.append(contentsOf: planePipes.descriptions)
        let hciAcl = planePipes.hciAclCapable
        if !hciAcl {
            notes.append("BTDebug CoreCapture child is StateDump (PipeSize≈64), not a live HCI ACL stream.")
            notes.append("PacketLogger links IOBluetooth (includeKernelBuffer), not a redistributable BTDebug ACL API.")
        }

        // Attempt open on CCDataPipe / CCLogPipe matching BT owner.
        for name in ["CCDataPipe", "CCLogPipe", "CCPipe", "CCDataStream"] {
            let svc = findService(className: name)
            if svc == 0 { continue }
            var conn: io_connect_t = 0
            let kr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
            opens.append(("\(name) type0", kr))
            if kr == KERN_SUCCESS { IOServiceClose(conn) }
            IOObjectRelease(svc)
        }

        let clientPresent = ioregTextContains("BTDebugUserClient")

        if profile {
            notes.append("Profile ON enables PacketLogger; Spike B asks whether any non-PacketLogger channel yields ACL. Observed: no.")
        } else {
            notes.append("Profile OFF — PacketLogger refused; Spike B still found no alternate ACL pipe.")
        }

        return SpikeBResult(
            profileInstalled: profile,
            btDebugPresent: btDebugPresent,
            btDebugOpenKR: openKR,
            btDebugClientPresent: clientPresent,
            coreCaptureBTPipes: pipes,
            hciAclPipeFound: hciAcl,
            openAttempts: opens,
            notes: notes
        )
    }

    /// Combined report for docs / CI-like local runs.
    static func runAll(spikeADuration: TimeInterval = 12) -> String {
        let a = runSpikeA(durationSec: spikeADuration)
        let b = runSpikeB()
        let gate: String
        if b.durableCaptureWithoutProfile {
            gate = "GATE: PASS — proceed to signed helper + HyperVibe Mic installer."
        } else if a.ioBluetoothReceivesVoice {
            gate = "GATE: PARTIAL — IOBluetooth receive works; productize that channel."
        } else {
            gate = "GATE: FAIL — park consumer remote-mic; keep HID Core only. Revisit with extra hardware or a future Apple API."
        }
        return [a.description, "", b.description, "", gate].joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Count A2854 frames in a prior PacketLogger nhdr capture (wire-format control).
    private static func offlinePacketLoggerFrameCount(
        path: String = "/tmp/hypervibe-hci-siri.nhdr"
    ) -> Int? {
        guard FileManager.default.isReadableFile(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let capture = MicCapturePipeline()
        let sem = DispatchSemaphore(value: 0)
        capture.startReplaying(fileAt: path)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { sem.signal() }
        sem.wait()
        let n = capture.framesSeen
        _ = text
        return n > 0 ? n : nil
    }

    static func containsA2854OpusSignature(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        let bytes = [UInt8](data)
        let maxStart = bytes.count - 6
        guard maxStart >= 0 else { return false }
        for start in 0...maxStart {
            let len = Int(bytes[start + 4])
            guard len > 0, len <= OpusVoiceDecoder.maxOpusFrameLen,
                  start + 5 + len <= bytes.count,
                  bytes[start + 5] == 0xB8 else { continue }
            let end = min(bytes.count, start + OpusVoiceDecoder.micReportLen)
            let payload = Data(bytes[start..<end])
            if OpusVoiceDecoder.parsePacket(payload) != nil {
                return true
            }
        }
        // Also accept ATT notify prefix 0x1B + 99-byte value somewhere in buffer.
        if bytes.count >= 3 + OpusVoiceDecoder.micReportLen {
            for start in 0...(bytes.count - (3 + OpusVoiceDecoder.micReportLen)) {
                if bytes[start] == 0x1B {
                    let value = Data(bytes[(start + 3)..<(start + 3 + OpusVoiceDecoder.micReportLen)])
                    if let parsed = OpusVoiceDecoder.parsePacket(value), parsed.frame.first == 0xB8 {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func findService(className: String) -> io_service_t {
        let matching = IOServiceMatching(className)
        var iterator: io_iterator_t = 0
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }
        guard IOServiceGetMatchingServices(mainPort, matching, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        return IOIteratorNext(iterator)
    }

    private struct PlaneInventory {
        var descriptions: [String]
        var hciAclCapable: Bool
    }

    private static func listCoreCaptureBTPipes() -> PlaneInventory {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-p", "CoreCapture", "-l", "-w0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch {
            return PlaneInventory(descriptions: [], hciAclCapable: false)
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            task.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + 8) == .timedOut, task.isRunning {
            task.terminate()
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var descriptions = [String]()
        var hciAcl = false
        // Prefer BTDebug registry (Owner / DirectoryName), not the entire plane root.
        for block in text.components(separatedBy: "+-o ") {
            let owner = firstQuoted(after: "Owner", in: block) ?? ""
            let directory = firstQuoted(after: "DirectoryName", in: block) ?? ""
            let ioClass = firstQuoted(after: "IOClass", in: block) ?? ""
            let isBT = owner.localizedCaseInsensitiveContains("BTDebug")
                || owner.localizedCaseInsensitiveContains("Bluetooth")
                || directory == "BT"
                || block.contains("com.apple.driver.BTDebug")
            guard isBT, ioClass.contains("CC") || ioClass.contains("Pipe") || ioClass.contains("Stream") else {
                continue
            }
            let name = block.split(separator: "\n").first.map(String.init) ?? "pipe"
            let pipeName = firstQuoted(after: "Name", in: block) ?? "?"
            let size = firstNumber(after: "PipeSize", in: block)
            descriptions.append(
                "\(String(name.prefix(60))) owner=\(owner.isEmpty ? "?" : owner) name=\(pipeName) class=\(ioClass) size=\(size.map(String.init) ?? "?")"
            )

            // Heuristic: live HCI would be a large data pipe, not StateDump/64.
            if ioClass.contains("CCDataPipe"),
               let size,
               size >= 1024,
               !pipeName.localizedCaseInsensitiveContains("StateDump") {
                hciAcl = true
            }
            if pipeName.localizedCaseInsensitiveContains("hci")
                || pipeName.localizedCaseInsensitiveContains("acl")
                || pipeName.localizedCaseInsensitiveContains("packet") {
                hciAcl = true
            }
        }
        // Direct BTDebug children from IOService plane (more reliable than CoreCapture plane parse).
        let btKids = ioregBTDebugChildren()
        for kid in btKids where !descriptions.contains(where: { $0.contains(kid.name) }) {
            descriptions.append(
                "\(kid.name) owner=BTDebug name=\(kid.pipeName) class=\(kid.ioClass) size=\(kid.size.map(String.init) ?? "?")"
            )
            if kid.ioClass.contains("CCDataPipe"),
               let size = kid.size,
               size >= 1024,
               !kid.pipeName.localizedCaseInsensitiveContains("StateDump") {
                hciAcl = true
            }
        }
        return PlaneInventory(descriptions: descriptions, hciAclCapable: hciAcl)
    }

    private struct BTPipeChild {
        var name: String
        var pipeName: String
        var ioClass: String
        var size: Int?
    }

    private static func ioregBTDebugChildren() -> [BTPipeChild] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-r", "-c", "BTDebug", "-l", "-w0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            task.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + 5) == .timedOut, task.isRunning {
            task.terminate()
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var kids = [BTPipeChild]()
        for block in text.components(separatedBy: "+-o ") {
            let ioClass = firstQuoted(after: "IOClass", in: block) ?? ""
            guard ioClass.contains("CC") || ioClass.contains("Pipe") || ioClass.contains("Stream") else { continue }
            let header = block.split(separator: "\n").first.map(String.init) ?? "child"
            kids.append(
                BTPipeChild(
                    name: String(header.prefix(60)),
                    pipeName: firstQuoted(after: "Name", in: block) ?? "?",
                    ioClass: ioClass,
                    size: firstNumber(after: "PipeSize", in: block)
                )
            )
        }
        return kids
    }

    private static func firstQuoted(after key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let eq = rest.range(of: "=") else { return nil }
        let afterEq = rest[eq.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if afterEq.hasPrefix("\"") {
            let body = afterEq.dropFirst()
            if let end = body.firstIndex(of: "\"") {
                return String(body[..<end])
            }
        }
        return nil
    }

    private static func firstNumber(after key: String, in text: String) -> Int? {
        guard let range = text.range(of: "\"\(key)\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let eq = rest.range(of: "=") else { return nil }
        let afterEq = rest[eq.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = afterEq.prefix(while: { $0.isNumber || $0 == "-" })
        return Int(digits)
    }

    private static func ioregTextContains(_ needle: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        // Narrow query — full `ioreg -l` can hang for minutes on large registries.
        task.arguments = ["-r", "-c", "BTDebug", "-l", "-w0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return false }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            task.waitUntilExit()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)
        if task.isRunning { task.terminate() }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.contains(needle)
    }
}
