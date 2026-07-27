//
//  HCIHelperServer.swift
//  HyperVibeHCIHelper
//
//  Unix-socket server that owns MobileBluetooth.debug prefs + PacketLogger.
//

import Foundation

final class HCIHelperServer {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.hypervibe.hcihelper")
    private var captureProcess: Process?
    private var sessionDirectory: URL?
    private var prefsBackupURL: URL?
    private var hadPrefs = false
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

        let addrLen = socklen_t(
            MemoryLayout<sockaddr_un>.size
        )
        let bindOK: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrLen)
            }
        }
        guard bindOK == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        chmod(socketPath, 0o666)
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
            handleClient(client)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
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
            case let .start(packetLoggerPath, outputPath, tokenPath, parentPID):
                do {
                    try startCaptureLocked(
                        packetLoggerPath: packetLoggerPath,
                        outputPath: outputPath,
                        tokenPath: tokenPath,
                        parentPID: parentPID
                    )
                    return .ok
                } catch {
                    return .error(error.localizedDescription)
                }
            }
        }
        writeAll(HCIHelperCodec.encodeResponse(response), to: fd)
    }

    private func startCaptureLocked(
        packetLoggerPath: String,
        outputPath: String,
        tokenPath: String,
        parentPID: Int32
    ) throws {
        stopCaptureLocked()

        let fm = FileManager.default
        let outputURL = URL(fileURLWithPath: outputPath)
        let sessionDir = outputURL.deletingLastPathComponent()
        sessionDirectory = sessionDir
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try Data().write(to: outputURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: outputPath)
        if !fm.fileExists(atPath: tokenPath) {
            try Data("alive".utf8).write(to: URL(fileURLWithPath: tokenPath), options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: tokenPath)
        }

        let prefDomain = "/Library/Preferences/com.apple.MobileBluetooth.debug"
        let prefFile = prefDomain + ".plist"
        let backup = URL(fileURLWithPath: outputPath + ".preferences.plist")
        prefsBackupURL = backup
        hadPrefs = false
        try? fm.removeItem(at: backup)
        if fm.fileExists(atPath: prefFile) {
            let export = Process()
            export.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            export.arguments = ["export", prefDomain, backup.path]
            export.standardOutput = Pipe()
            export.standardError = Pipe()
            try export.run()
            export.waitUntilExit()
            hadPrefs = export.terminationStatus == 0
        }

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

        // Orphaned packetloggers from crashed helpers steal HCI and truncate mic audio.
        let killOrphans = Process()
        killOrphans.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killOrphans.arguments = ["-9", "packetlogger"]
        killOrphans.standardOutput = Pipe()
        killOrphans.standardError = Pipe()
        try? killOrphans.run()
        killOrphans.waitUntilExit()

        let signalBT = Process()
        signalBT.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        signalBT.arguments = ["-30", "bluetoothd"]
        signalBT.standardOutput = Pipe()
        signalBT.standardError = Pipe()
        try? signalBT.run()
        signalBT.waitUntilExit()
        Thread.sleep(forTimeInterval: 2)

        let outHandle = try FileHandle(forWritingTo: outputURL)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: packetLoggerPath)
        proc.arguments = ["convert", "-s", "-f", "nhdr"]
        proc.standardOutput = outHandle
        proc.standardError = outHandle
        try proc.run()
        try? outHandle.close()
        captureProcess = proc
        tokenWatchPath = tokenPath

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let parentAlive = kill(parentPID, 0) == 0
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
    }

    private func stopCaptureLocked() {
        parentWatchTimer?.cancel()
        parentWatchTimer = nil
        tokenWatchPath = nil

        if let proc = captureProcess, proc.isRunning {
            proc.interrupt()
            // Don't hang forever if PacketLogger ignores SIGINT.
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                proc.waitUntilExit()
                group.leave()
            }
            _ = group.wait(timeout: .now() + 2)
            if proc.isRunning {
                proc.terminate()
            }
        }
        captureProcess = nil

        // Always clear orphans — Process tracking alone loses children after helper restart.
        let killOrphans = Process()
        killOrphans.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killOrphans.arguments = ["-9", "packetlogger"]
        killOrphans.standardOutput = Pipe()
        killOrphans.standardError = Pipe()
        try? killOrphans.run()
        killOrphans.waitUntilExit()

        let prefDomain = "/Library/Preferences/com.apple.MobileBluetooth.debug"
        if hadPrefs, let backup = prefsBackupURL, FileManager.default.fileExists(atPath: backup.path) {
            let restore = Process()
            restore.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            restore.arguments = ["import", prefDomain, backup.path]
            restore.standardOutput = Pipe()
            restore.standardError = Pipe()
            try? restore.run()
            restore.waitUntilExit()
        } else {
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
        hadPrefs = false

        let signalBT = Process()
        signalBT.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        signalBT.arguments = ["-30", "bluetoothd"]
        signalBT.standardOutput = Pipe()
        signalBT.standardError = Pipe()
        try? signalBT.run()
        signalBT.waitUntilExit()

        // Leave capture.nhdr for the app to finish reading; the app removes the session dir.
        sessionDirectory = nil
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
