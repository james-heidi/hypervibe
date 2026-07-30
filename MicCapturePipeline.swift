//
//  MicCapturePipeline.swift
//  HyperVibe
//
//  Spawn Apple PacketLogger HCI convert stream and extract A2854 Opus frames.
//

import Foundation

enum MicCaptureStatus: Equatable {
    case idle
    case missingTools(String)
    case starting
    case listening
    case streaming
    case error(String)

    var menuLabel: String {
        switch self {
        case .idle: return "麦克风: 关闭"
        case .missingTools(let detail): return "麦克风: 缺工具 (\(detail))"
        case .starting: return "麦克风: 启动中…"
        case .listening: return "麦克风: 等待语音帧"
        case .streaming: return "麦克风: 采集中"
        case .error(let msg): return "麦克风: 错误 — \(msg)"
        }
    }
}

/// Captures BLE HCI via `packetlogger convert -s -f nhdr` and yields A2854 payloads.
final class MicCapturePipeline {
    var onStatus: ((MicCaptureStatus) -> Void)?
    var onPayload: ((Data) -> Void)?

    private var helperSessionActive = false
    private var restartAfterTeardown = false
    private var fileReadTimer: DispatchSourceTimer?
    private var helperWatchTimer: DispatchSourceTimer?
    private var captureDirectory: URL?
    private var captureOutputURL: URL?
    private var captureTokenURL: URL?
    private var captureReadOffset: UInt64 = 0
    private let queue = DispatchQueue(label: "com.hypervibe.mic-capture")
    private var buffer = Data()
    private var remoteAddress: String
    private struct ACLAssembly {
        let cid: UInt16
        let expectedLength: Int
        var bytes: [UInt8]
    }
    private var aclAssemblies: [UInt16: ACLAssembly] = [:]
    private(set) var status: MicCaptureStatus = .idle {
        didSet { DispatchQueue.main.async { self.onStatus?(self.status) } }
    }

    private(set) var framesSeen: Int = 0

    init(remoteAddress: String? = nil) {
        self.remoteAddress = (remoteAddress ?? Self.detectRemoteAddress() ?? "")
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
    }

    static func packetLoggerURL() -> URL? {
        var candidates = [String]()
        if let resources = Bundle.main.resourceURL {
            candidates.append(
                resources
                    .appendingPathComponent("Tools/PacketLogger.app/Contents/Resources/packetlogger")
                    .path
            )
        }
        candidates.append(contentsOf: [
            "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
            "\(NSHomeDirectory())/Applications/PacketLogger.app/Contents/Resources/packetlogger",
            "\(NSHomeDirectory())/Downloads/PacketLogger.app/Contents/Resources/packetlogger",
            "/usr/local/bin/packetlogger",
            "\(NSHomeDirectory())/Desktop/SiriRemote/PacketLogger.app/Contents/Resources/packetlogger",
        ])
        if let path = PacketLoggerLocator.firstExecutable(candidates: candidates) {
            return URL(fileURLWithPath: path)
        }
        // Search Additional Tools DMG mounts
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for vol in volumes {
            let path = "/Volumes/\(vol)/Hardware/PacketLogger.app/Contents/Resources/packetlogger"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func bluetoothProfileInstalled() -> Bool {
        // Diagnostic profiles install at device scope, while `profiles list`
        // only reports profiles for the current user on recent macOS.
        let managedPayloads = [
            "/Library/Managed Preferences/com.apple.MobileBluetooth.debug.plist",
            "/Library/Managed Preferences/com.apple.corecapture.configure.bt.plist",
        ]
        if managedPayloads.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
            return true
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.localizedCaseInsensitiveContains("bluetooth")
            && text.localizedCaseInsensitiveContains("logging")
    }

    static func detectRemoteAddress() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let knownRemotePIDs = RemoteAdapterRegistry.allKnownProductIDs

        // Walk each connected-device block. A block opens at a device-name header (a
        // trimmed line ending in ":" that is not a "Key: value" property) and matches
        // either by a known remote product ID or an "Apple TV Remote"-style name. The
        // A2540 advertises a bare serial (e.g. DL3FN09R17FC), so the product-ID check
        // is what actually catches it; the name check keeps older remotes working.
        func isNameHeader(_ line: String) -> Bool {
            guard line.hasSuffix(":") else { return false }
            return !line.dropLast().contains(":")
        }

        var inConnected = false
        var currentAddress: String?
        var nameLooksLikeRemote = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("Connected:") { inConnected = true; continue }
            if line.hasPrefix("Not Connected:") { break }
            guard inConnected else { continue }

            if isNameHeader(line) {
                currentAddress = nil
                let lower = line.lowercased()
                nameLooksLikeRemote = lower.contains("remote")
                    || lower.contains("siri") || lower.contains("apple tv")
            } else if line.hasPrefix("Address:") {
                currentAddress = line
                    .replacingOccurrences(of: "Address:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if nameLooksLikeRemote, let addr = currentAddress { return addr }
            } else if line.hasPrefix("Product ID:") {
                let hex = line
                    .replacingOccurrences(of: "Product ID:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "0x", with: "")
                if let pid = Int(hex, radix: 16), knownRemotePIDs.contains(pid),
                   let addr = currentAddress {
                    return addr
                }
            }
        }
        return nil
    }

    /// Offline replay of a PacketLogger nhdr text capture (for tests / gated validation).
    func startReplaying(fileAt path: String) {
        queue.async {
            self.stopSync()
            self.status = .starting
            self.framesSeen = 0
            self.aclAssemblies.removeAll()
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                self.status = .error("cannot read \(path)")
                return
            }
            self.status = .listening
            for line in text.components(separatedBy: .newlines) {
                self.handleLine(line)
            }
            if self.framesSeen == 0 {
                self.status = .error("no A2854 frames in \(path)")
            }
            rmDebug("🎤 replay finished frames=\(self.framesSeen)")
        }
    }

    func start() {
        queue.async {
            if self.helperSessionActive {
                self.restartAfterTeardown = true
                return
            }
            self.restartAfterTeardown = false
            guard let logger = Self.packetLoggerURL() else {
                self.status = .missingTools("PacketLogger")
                rmDebug("🎤 PacketLogger binary not found — will retry")
                // Retry periodically so installing tools mid-session recovers without relaunch.
                self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, !self.helperSessionActive else { return }
                    if case .missingTools = self.status {
                        self.start()
                    }
                }
                return
            }
            guard HCIHelperClient.isReady() else {
                self.status = .missingTools("麦克风组件")
                rmDebug("🎤 HCI helper not installed/ready")
                return
            }
            self.status = .starting
            self.framesSeen = 0
            self.buffer.removeAll(keepingCapacity: true)
            self.aclAssemblies.removeAll()
            self.startHelperCapture(logger: logger)
        }
    }

    /// Starts PacketLogger through the one-shot installed LaunchDaemon helper.
    /// Admin password is only required when installing that helper, not per capture.
    private func startHelperCapture(logger: URL) {
        guard HCIHelperPathValidation.isAllowedPacketLoggerPath(logger.path) else {
            status = .error("packetlogger path rejected")
            rmDebug("🎤 packetlogger path rejected: \(logger.path)")
            return
        }

        captureDirectory = nil
        captureOutputURL = nil
        captureTokenURL = nil
        captureReadOffset = 0

        do {
            let response = try HCIHelperClient.send(
                .start(
                    packetLoggerPath: logger.path,
                    parentPID: getpid()
                ),
                timeout: 12
            )
            guard case let .started(outputPath, tokenPath) = response else {
                status = .error("helper did not return session paths")
                return
            }
            captureOutputURL = URL(fileURLWithPath: outputPath)
            captureTokenURL = URL(fileURLWithPath: tokenPath)
            captureDirectory = captureOutputURL?.deletingLastPathComponent()
        } catch {
            status = .error(error.localizedDescription)
            removeCaptureDirectory()
            rmDebug("🎤 helper start failed: \(error)")
            return
        }

        helperSessionActive = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 20 ms, not 100: a 100 ms tail poll clumped voice frames into bursts, and the
        // HUD level could only be as fresh as the clump. The read is an open+seek+tail
        // on a file growing ~10 KB/s, and the rotation guard below still bounds its size.
        timer.schedule(deadline: .now() + Self.captureTailPollInterval,
                       repeating: Self.captureTailPollInterval)
        timer.setEventHandler { [weak self] in
            self?.readPrivilegedOutput()
        }
        fileReadTimer = timer
        timer.resume()

        // Poll helper status off the capture queue so a slow ping cannot stall audio reads.
        let statusQueue = DispatchQueue(label: "com.hypervibe.mic-capture.status")
        let watch = DispatchSource.makeTimerSource(queue: statusQueue)
        watch.schedule(deadline: .now() + 1.0, repeating: 1.0)
        watch.setEventHandler { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.helperSessionActive else { return }
            }
            if case .status(let value) = try? HCIHelperClient.send(.status, timeout: 1.0),
               value == "idle" {
                self.queue.async {
                    // Unexpected helper exit must self-heal; otherwise the next Siri
                    // press is forced through a cold start.
                    self.restartAfterTeardown = true
                    self.finishHelperSession(restartIfNeeded: true)
                }
            }
        }
        helperWatchTimer = watch
        watch.resume()

        status = .listening
        rmDebug("🎤 helper capture started addr=\(remoteAddress.isEmpty ? "*" : remoteAddress)")
    }

    func stop() {
        queue.async { self.stopSync() }
    }

    private func stopSync() {
        status = .idle
        restartAfterTeardown = false
        // Drop the liveness token and ask the helper to stop PacketLogger / restore prefs.
        if let token = captureTokenURL {
            try? FileManager.default.removeItem(at: token)
        }
        if helperSessionActive {
            _ = try? HCIHelperClient.send(.stop, timeout: 5)
        }
        finishHelperSession(restartIfNeeded: false)
        buffer.removeAll()
        aclAssemblies.removeAll()
    }

    private func finishHelperSession(restartIfNeeded: Bool) {
        teardownIO()
        helperSessionActive = false
        removeCaptureDirectory()
        if restartIfNeeded, restartAfterTeardown {
            restartAfterTeardown = false
            start()
            return
        }
        if case .error = status {
            return
        }
        if status != .idle {
            status = .idle
        }
    }

    private func teardownIO() {
        fileReadTimer?.cancel()
        fileReadTimer = nil
        helperWatchTimer?.cancel()
        helperWatchTimer = nil
    }

    private func removeCaptureDirectory() {
        // Helper owns the session directory under /var/tmp; only drop the liveness token.
        if let token = captureTokenURL {
            try? FileManager.default.removeItem(at: token)
        }
        captureDirectory = nil
        captureOutputURL = nil
        captureTokenURL = nil
        captureReadOffset = 0
    }

    private static let captureRotateBytes: UInt64 = 32 * 1024 * 1024
    private static let captureTailPollInterval: TimeInterval = 0.02

    private func readPrivilegedOutput() {
        guard let output = captureOutputURL,
              let handle = try? FileHandle(forReadingFrom: output) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: captureReadOffset)
            let chunk = try handle.readToEnd() ?? Data()
            guard !chunk.isEmpty else {
                // Rotate long-lived warm sessions before capture.nhdr grows without bound.
                if captureReadOffset > Self.captureRotateBytes {
                    rmDebug("🎤 rotating capture after \(captureReadOffset) bytes")
                    restartAfterTeardown = true
                    if let token = captureTokenURL {
                        try? FileManager.default.removeItem(at: token)
                    }
                    _ = try? HCIHelperClient.send(.stop, timeout: 5)
                    finishHelperSession(restartIfNeeded: true)
                }
                return
            }
            captureReadOffset += UInt64(chunk.count)
            DictationTiming.logOnce(.firstCaptureRead, detail: "bytes=\(chunk.count)")
            if status == .starting {
                status = .listening
            }
            buffer.append(chunk)
            consumeBufferedLines()
        } catch {
            rmDebug("🎤 capture tail read failed: \(error)")
        }
    }

    private func readAvailable(from handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty { return }
        buffer.append(chunk)
        consumeBufferedLines()
    }

    private func consumeBufferedLines() {
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                handleLine(line)
            }
        }
        // Cap runaway buffer
        if buffer.count > 1_000_000 {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func handleLine(_ line: String) {
        // PacketLogger nhdr text: RECV/SEND + hex payload. Event lines carry a BD_ADDR;
        // ACL data lines are keyed by connection handle only (see the split below).
        let upper = line.uppercased()
        guard upper.contains("RECV") else { return }

        let payload: Data?
        if let packet = Self.hciACLPacket(from: line) {
            // Voice arrives as ACL data keyed by connection handle; nhdr does NOT
            // stamp a BD_ADDR on ACL lines, so the address pre-filter below must be
            // skipped here or every voice frame is dropped. The strict ATT/Opus
            // checks in consumeACL are the real filter.
            // PacketLogger emits the 102-byte ATT notification over a 90-byte
            // first ACL fragment plus a 16-byte continuation. Reassemble before
            // interpreting the 99-byte A2854 report.
            payload = consumeACL(packet)
        } else {
            // Non-ACL lines carry a BD_ADDR: keep the address pre-filter so a
            // synthetic / reassembled trace doesn't decode another device's traffic.
            if !remoteAddress.isEmpty {
                let compactRemote = remoteAddress.replacingOccurrences(of: ":", with: "")
                let compactLine = upper.replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "-", with: "")
                // Allow all-zero addr quirk from PacketLogger and exact match.
                let wildcard = upper.contains("00:00:00:00:00:00")
                let namedRemote = upper.contains("APPLE TV") && upper.contains("REMOTE")
                if !wildcard && !namedRemote
                    && !upper.contains(remoteAddress) && !compactLine.contains(compactRemote) {
                    return
                }
            }
            payload = Self.extractA2854Payload(from: line)
        }
        guard let payload else { return }
        framesSeen += 1
        if status != .streaming {
            status = .streaming
            rmDebug("🎤 first A2854 voice frame (\(payload.count) bytes)")
        }
        onPayload?(payload)
    }

    /// Pull a 99-byte A2854 mic payload (or ATT value containing one) out of an nhdr line.
    static func extractA2854Payload(from line: String) -> Data? {
        let bytes = hexBytes(afterRecvIn: line)
        guard bytes.count >= 6 else { return nil }

        // Find a report header followed by the expected A2854 Opus TOC.
        for start in 0...(bytes.count - 6) {
            let len = Int(bytes[start + 4])
            guard len > 0, len <= OpusVoiceDecoder.maxOpusFrameLen,
                  bytes[start + 5] == 0xB8,
                  start + 5 + len <= bytes.count else { continue }
            let end = min(bytes.count, start + OpusVoiceDecoder.micReportLen)
            let payload = Data(bytes[start..<end])
            if OpusVoiceDecoder.parsePacket(payload) != nil {
                return payload
            }
        }
        return nil
    }

    private static func hexBytes(afterRecvIn line: String) -> [UInt8] {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let recvIndex = tokens.firstIndex(where: { $0.uppercased() == "RECV" })
        let candidates = recvIndex.map { tokens[tokens.index(after: $0)...] } ?? tokens[...]
        var bytes = [UInt8]()
        bytes.reserveCapacity(candidates.count)
        for tok in candidates {
            let cleaned = tok.trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
            guard cleaned.count == 2,
                  cleaned.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
                  let b = UInt8(cleaned, radix: 16) else { continue }
            bytes.append(b)
        }
        return bytes
    }

    private static func hciACLPacket(from line: String)
        -> (handle: UInt16, pb: UInt8, data: [UInt8])? {
        let bytes = hexBytes(afterRecvIn: line)
        guard bytes.count >= 4 else { return nil }
        let handleFlags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let pb = UInt8((handleFlags >> 12) & 0x03)
        guard pb == 1 || pb == 2 else { return nil }
        let dataLength = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard dataLength > 0, bytes.count >= 4 + dataLength else { return nil }
        return (
            handle: handleFlags & 0x0FFF,
            pb: pb,
            data: Array(bytes[4..<(4 + dataLength)])
        )
    }

    private func consumeACL(
        _ packet: (handle: UInt16, pb: UInt8, data: [UInt8])
    ) -> Data? {
        if packet.pb == 2 {
            guard packet.data.count >= 4 else { return nil }
            let expected = Int(packet.data[0]) | (Int(packet.data[1]) << 8)
            let cid = UInt16(packet.data[2]) | (UInt16(packet.data[3]) << 8)
            aclAssemblies[packet.handle] = ACLAssembly(
                cid: cid,
                expectedLength: expected,
                bytes: Array(packet.data.dropFirst(4))
            )
        } else if var assembly = aclAssemblies[packet.handle] {
            assembly.bytes.append(contentsOf: packet.data)
            aclAssemblies[packet.handle] = assembly
        } else {
            return nil
        }

        guard let assembly = aclAssemblies[packet.handle],
              assembly.bytes.count >= assembly.expectedLength else { return nil }
        aclAssemblies.removeValue(forKey: packet.handle)

        guard assembly.cid == 0x0004, assembly.expectedLength >= 102 else { return nil }
        let pdu = Array(assembly.bytes.prefix(assembly.expectedLength))
        guard pdu.count >= 3 + OpusVoiceDecoder.micReportLen,
              pdu[0] == 0x1B else { return nil }
        let value = Data(pdu[3..<(3 + OpusVoiceDecoder.micReportLen)])
        guard let parsed = OpusVoiceDecoder.parsePacket(value),
              parsed.frame.first == 0xB8 else {
            return nil
        }
        return value
    }
}
