//
//  HCIHelperServer.swift
//  HyperVibeHCIHelper
//
//  Unix-socket server that owns MobileBluetooth.debug prefs + PacketLogger.
//

import Foundation
import Darwin
import SystemConfiguration

final class HCIHelperServer {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.hypervibe.hcihelper")
    private let clientQueue = DispatchQueue(
        label: "com.hypervibe.hcihelper.clients",
        attributes: .concurrent
    )
    private var captureProcess: Process?
    private var capturePID: pid_t = 0
    private var sessionDirectory: URL?
    private var prefsBackupURL: URL?
    /// True only after this session successfully wrote MobileBluetooth.debug prefs.
    private var prefsModified = false
    /// True when a pre-existing prefs domain was backed up before modification.
    private var hadPrefsBackup = false
    private var parentWatchTimer: DispatchSourceTimer?
    private var tokenWatchPath: String?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func run() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() {
                buf[i] = b
            }
            buf[pathBytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrLen)
            }
        }
        guard bindOK == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Defense in depth: root:staff 0660 lets human console users connect while
        // blocking daemon/service accounts at the filesystem. We can't chown to the
        // console user here — the daemon starts at boot, before login, and the
        // console user changes with fast user switching. Peer-cred auth in
        // handleClient is the authoritative gate.
        chown(socketPath, 0, 20) // root:staff
        chmod(socketPath, 0o660)
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        fputs("HyperVibeHCIHelper listening on \(socketPath)\n", stderr)

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                continue
            }
            clientQueue.async { [weak self] in
                self?.handleClient(client)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        setSocketTimeouts(fd, seconds: 5)

        guard let peer = peerCredentials(fd) else {
            writeAll(HCIHelperCodec.encodeResponse(.error("unauthorized")), to: fd)
            return
        }
        guard isAuthorizedPeer(peer) else {
            writeAll(HCIHelperCodec.encodeResponse(.error("unauthorized")), to: fd)
            return
        }

        guard let line = readLine(from: fd),
              let request = HCIHelperCodec.decodeRequest(line) else {
            writeAll(HCIHelperCodec.encodeResponse(.error("bad request")), to: fd)
            return
        }

        let response: HCIHelperResponse = queue.sync {
            switch request {
            case .ping:
                return .pong
            case .status:
                if captureProcess?.isRunning == true {
                    return .status("running")
                }
                return .status("idle")
            case .stop:
                stopCaptureLocked()
                return .ok
            case let .start(packetLoggerPath, parentPID):
                do {
                    let paths = try startCaptureLocked(
                        packetLoggerPath: packetLoggerPath,
                        parentPID: parentPID,
                        peerUID: peer.uid
                    )
                    return .started(outputPath: paths.output, tokenPath: paths.token)
                } catch {
                    return .error(error.localizedDescription)
                }
            }
        }
        writeAll(HCIHelperCodec.encodeResponse(response), to: fd)
    }

    private struct PeerCred {
        let uid: uid_t
        let pid: pid_t
    }

    private func peerCredentials(_ fd: Int32) -> PeerCred? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let kr = withUnsafeMutablePointer(to: &cred) { credPtr -> Int32 in
            credPtr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<xucred>.size) { raw in
                getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, raw, &len)
            }
        }
        guard kr == 0 else { return nil }

        var pid: pid_t = 0
        var pidLen = socklen_t(MemoryLayout<pid_t>.size)
        _ = withUnsafeMutablePointer(to: &pid) { pidPtr in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEEREPID, pidPtr, &pidLen)
        }
        return PeerCred(uid: cred.cr_uid, pid: pid)
    }

    private func isAuthorizedPeer(_ peer: PeerCred) -> Bool {
        // Never accept root-to-root anonymous clients; require a real console user.
        guard peer.uid != 0 else { return false }
        var consoleUID: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) as String?,
              !name.isEmpty else {
            // Fall back: allow any non-root peer when console user is unavailable (SSH).
            return true
        }
        _ = name
        return peer.uid == consoleUID
    }

    private func setSocketTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: __darwin_time_t(seconds), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func startCaptureLocked(
        packetLoggerPath: String,
        parentPID: Int32,
        peerUID: uid_t
    ) throws -> (output: String, token: String) {
        stopCaptureLocked()

        guard HCIHelperPathValidation.isAllowedPacketLoggerPath(packetLoggerPath) else {
            throw NSError(
                domain: "HyperVibeHCIHelper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "packetlogger path rejected"]
            )
        }
        let resolvedLogger = URL(fileURLWithPath: packetLoggerPath).resolvingSymlinksInPath().path

        let fm = FileManager.default
        try fm.createDirectory(
            atPath: HCIHelperPaths.sessionRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let sessionDir = URL(fileURLWithPath: HCIHelperPaths.sessionRoot)
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionDir.path)

        let outputURL = sessionDir.appendingPathComponent("capture.nhdr")
        let tokenURL = sessionDir.appendingPathComponent("capture.alive")
        try Data().write(to: outputURL, options: .atomic)
        try Data("alive".utf8).write(to: tokenURL, options: .atomic)
        // Readable by the peer; token writable so the app can unlink it to signal stop.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outputURL.path)
        try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: tokenURL.path)
        chown(outputURL.path, peerUID, 0)
        chown(tokenURL.path, peerUID, 0)
        sessionDirectory = sessionDir

        let prefDomain = "/Library/Preferences/com.apple.MobileBluetooth.debug"
        let prefFile = prefDomain + ".plist"
        let backup = sessionDir.appendingPathComponent("preferences-backup.plist")
        prefsBackupURL = backup
        hadPrefsBackup = false
        prefsModified = false
        try? fm.removeItem(at: backup)

        if fm.fileExists(atPath: prefFile) {
            let export = Process()
            export.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            export.arguments = ["export", prefDomain, backup.path]
            export.standardOutput = Pipe()
            export.standardError = Pipe()
            try export.run()
            export.waitUntilExit()
            guard export.terminationStatus == 0 else {
                throw NSError(
                    domain: "HyperVibeHCIHelper",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "cannot backup existing MobileBluetooth.debug prefs"]
                )
            }
            hadPrefsBackup = true
        }

        do {
            let write = Process()
            write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            write.arguments = [
                "write", prefDomain, "HCITraces", "-dict",
                "StackDebugEnabled", "-bool", "true",
                "HCILiveTraces", "-bool", "true",
                "HCIFileTraces", "-bool", "true",
                "RawAudioTrace", "-bool", "true",
                "HIDTrace", "-bool", "true",
                "HCISkipAuth", "-bool", "true",
            ]
            write.standardOutput = Pipe()
            write.standardError = Pipe()
            try write.run()
            write.waitUntilExit()
            guard write.terminationStatus == 0 else {
                throw NSError(
                    domain: "HyperVibeHCIHelper",
                    code: Int(write.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "defaults write failed"]
                )
            }
            prefsModified = true

            // Attach PacketLogger before asking bluetoothd to reload trace prefs.
            // It remains subscribed through the restart, eliminating the fixed 2s
            // open-loop sleep while still catching the first available HCI frames.
            let outHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outHandle.close() }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: resolvedLogger)
            proc.arguments = ["convert", "-s", "-f", "nhdr"]
            proc.standardOutput = outHandle
            proc.standardError = outHandle
            try proc.run()
            captureProcess = proc
            capturePID = proc.processIdentifier
            tokenWatchPath = tokenURL.path

            let signalBT = Process()
            signalBT.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            signalBT.arguments = ["-30", "bluetoothd"]
            signalBT.standardOutput = Pipe()
            signalBT.standardError = Pipe()
            try? signalBT.run()
            signalBT.waitUntilExit()

            // A short bounded settle catches immediate logger failures without
            // imposing the previous two-second cold-start penalty.
            usleep(150_000)
            guard proc.isRunning else {
                throw NSError(
                    domain: "HyperVibeHCIHelper",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "PacketLogger exited during Bluetooth reload"]
                )
            }

            let watchedParent = parentPID
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let parentAlive = kill(watchedParent, 0) == 0
                let tokenAlive = self.tokenWatchPath.map {
                    FileManager.default.fileExists(atPath: $0)
                } ?? false
                let captureAlive = self.captureProcess?.isRunning == true
                if !parentAlive || !tokenAlive || !captureAlive {
                    self.stopCaptureLocked()
                }
            }
            parentWatchTimer = timer
            timer.resume()

            return (outputURL.path, tokenURL.path)
        } catch {
            restorePrefsLocked()
            if let dir = sessionDirectory {
                try? FileManager.default.removeItem(at: dir)
            }
            sessionDirectory = nil
            captureProcess = nil
            capturePID = 0
            throw error
        }
    }

    private func stopCaptureLocked() {
        parentWatchTimer?.cancel()
        parentWatchTimer = nil
        tokenWatchPath = nil

        if let proc = captureProcess, proc.isRunning {
            let pid = proc.processIdentifier
            proc.interrupt()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                proc.waitUntilExit()
                group.leave()
            }
            _ = group.wait(timeout: .now() + 2)
            if proc.isRunning {
                proc.terminate()
                _ = group.wait(timeout: .now() + 1)
            }
            // Kill only our tracked PID — never killall packetlogger.
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        } else if capturePID > 0, kill(capturePID, 0) == 0 {
            kill(capturePID, SIGTERM)
            usleep(200_000)
            if kill(capturePID, 0) == 0 {
                kill(capturePID, SIGKILL)
            }
        }
        captureProcess = nil
        capturePID = 0

        restorePrefsLocked()

        if prefsModified {
            let signalBT = Process()
            signalBT.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            signalBT.arguments = ["-30", "bluetoothd"]
            signalBT.standardOutput = Pipe()
            signalBT.standardError = Pipe()
            try? signalBT.run()
            signalBT.waitUntilExit()
        }

        if let dir = sessionDirectory {
            // Leave a brief window for the app to finish reading; remove on next start or stop.
            try? FileManager.default.removeItem(at: dir)
        }
        sessionDirectory = nil
    }

    private func restorePrefsLocked() {
        guard prefsModified else {
            prefsBackupURL = nil
            hadPrefsBackup = false
            return
        }
        let prefDomain = "/Library/Preferences/com.apple.MobileBluetooth.debug"
        if hadPrefsBackup, let backup = prefsBackupURL,
           FileManager.default.fileExists(atPath: backup.path) {
            let restore = Process()
            restore.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            restore.arguments = ["import", prefDomain, backup.path]
            restore.standardOutput = Pipe()
            restore.standardError = Pipe()
            try? restore.run()
            restore.waitUntilExit()
        } else {
            // We created the domain from scratch — delete only what we added.
            let delete = Process()
            delete.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            delete.arguments = ["delete", prefDomain]
            delete.standardOutput = Pipe()
            delete.standardError = Pipe()
            try? delete.run()
            delete.waitUntilExit()
            try? FileManager.default.removeItem(atPath: prefDomain + ".plist")
        }
        if let backup = prefsBackupURL {
            try? FileManager.default.removeItem(at: backup)
        }
        prefsBackupURL = nil
        hadPrefsBackup = false
        prefsModified = false
    }

    private func readLine(from fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
            if data.count > 16_384 { break }
        }
        guard !data.isEmpty || byte == 0x0A else { return nil }
        return String(data: data, encoding: .utf8).map { $0 + "\n" }
    }

    private func writeAll(_ string: String, to fd: Int32) {
        guard let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = data.count
            var ptr = base
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { break }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }
}
