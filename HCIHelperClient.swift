//
//  HCIHelperClient.swift
//  HyperVibe
//
//  User-space client for the installed HyperVibeHCIHelper LaunchDaemon.
//

import AppKit
import Foundation

enum HCIHelperClient {
    enum ClientError: LocalizedError {
        case notInstalled
        case connectFailed(String)
        case badResponse(String)
        case helper(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "麦克风组件未安装"
            case .connectFailed(let message):
                return "无法连接麦克风组件: \(message)"
            case .badResponse(let message):
                return "麦克风组件响应异常: \(message)"
            case .helper(let message):
                return message
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedReady: Bool?
    private static var cacheDate: Date?
    private static let cacheTTL: TimeInterval = 2.0

    static func ping(timeout: TimeInterval = 1.0) -> Bool {
        (try? send(.ping, timeout: timeout)) == .pong
    }

    static func isReady() -> Bool {
        let ready = HCIHelperPaths.isInstalled && ping()
        cacheLock.lock()
        cachedReady = ready
        cacheDate = Date()
        cacheLock.unlock()
        return ready
    }

    /// Fast path for menu rebuilds — avoids a blocking socket round-trip every open.
    static func isReadyCached() -> Bool {
        cacheLock.lock()
        if let ready = cachedReady, let date = cacheDate,
           Date().timeIntervalSince(date) < cacheTTL {
            cacheLock.unlock()
            return ready
        }
        cacheLock.unlock()
        return isReady()
    }

    static func invalidateReadyCache() {
        cacheLock.lock()
        cachedReady = nil
        cacheDate = nil
        cacheLock.unlock()
    }

    @discardableResult
    static func send(
        _ request: HCIHelperRequest,
        socketPath: String = HCIHelperPaths.socketPath,
        timeout: TimeInterval = 8.0
    ) throws -> HCIHelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectFailed("socket()") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ClientError.connectFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() {
                buf[i] = b
            }
            buf[pathBytes.count] = 0
        }

        let connected: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let err = errno
            close(fd)
            if !HCIHelperPaths.isInstalled {
                throw ClientError.notInstalled
            }
            throw ClientError.connectFailed(String(cString: strerror(err)))
        }
        defer { close(fd) }

        let payload = HCIHelperCodec.encode(request)
        guard let data = payload.data(using: .utf8) else {
            throw ClientError.badResponse("encode failed")
        }
        let wrote = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        guard wrote == data.count else {
            throw ClientError.connectFailed("write failed")
        }

        // START may block while the helper reloads bluetoothd (~2s).
        var tv = timeval(
            tv_sec: __darwin_time_t(timeout),
            tv_usec: 0
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var responseData = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            responseData.append(byte)
            if byte == 0x0A { break }
            if responseData.count > 16_384 { break }
        }
        guard let line = String(data: responseData, encoding: .utf8),
              let response = HCIHelperCodec.decodeResponse(line) else {
            throw ClientError.badResponse(String(data: responseData, encoding: .utf8) ?? "<empty>")
        }
        if case .error(let message) = response {
            throw ClientError.helper(message)
        }
        return response
    }

    /// One-time admin install of the LaunchDaemon helper. Returns true on success.
    /// Script is piped via base64 on stdin to avoid TOCTOU on a user-writable temp file.
    @discardableResult
    static func installWithAdminPrompt(bundledHelperURL: URL) -> Bool {
        let script = HCIHelperInstall.makeInstallScript(helperSourcePath: bundledHelperURL.path)
        guard let scriptData = script.data(using: .utf8) else { return false }
        let b64 = scriptData.base64EncodedString()
        // Privileged sh decodes and runs the script from a pipe — never a user-writable path.
        let command = "echo \(ShellQuote.single(b64)) | /usr/bin/base64 -D | /bin/sh"
        return runAdminShell(command, failureTitle: "安装麦克风组件失败")
    }

    static func uninstallWithAdminPrompt() -> Bool {
        let script = HCIHelperInstall.makeUninstallScript()
        guard let scriptData = script.data(using: .utf8) else { return false }
        let b64 = scriptData.base64EncodedString()
        let command = "echo \(ShellQuote.single(b64)) | /usr/bin/base64 -D | /bin/sh"
        return runAdminShell(command, failureTitle: nil)
    }

    private static func runAdminShell(_ command: String, failureTitle: String?) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let proc = Process()
        let err = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        proc.standardOutput = Pipe()
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            if let failureTitle {
                presentAlert(title: failureTitle, message: error.localizedDescription)
            }
            return false
        }
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            if errText.localizedCaseInsensitiveContains("User canceled")
                || errText.localizedCaseInsensitiveContains("User cancelled") {
                return false
            }
            if let failureTitle {
                presentAlert(
                    title: failureTitle,
                    message: errText.isEmpty ? "exit \(proc.terminationStatus)" : errText
                )
            }
            return false
        }

        if failureTitle != nil {
            invalidateReadyCache()
            for _ in 0..<20 {
                if isReady() { return true }
                Thread.sleep(forTimeInterval: 0.15)
            }
            presentAlert(
                title: "麦克风组件已安装但尚未就绪",
                message: "请稍候再试，或重新打开 HyperVibe。"
            )
            return isReady()
        }
        invalidateReadyCache()
        return true
    }

    private static func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert.hyperVibeAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runHyperVibeModal()
        }
    }
}
