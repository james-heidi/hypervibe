//
//  HCIHelperProtocol.swift
//  HyperVibe
//
//  Shared framing for the one-shot privileged HCI helper LaunchDaemon.
//  Install once with admin; every later capture is a local socket round-trip.
//

import Foundation

enum HCIHelperPaths {
    static let launchdLabel = "com.hypervibe.hcihelper"
    static let helperBinary = "/Library/PrivilegedHelperTools/com.hypervibe.hcihelper"
    static let launchdPlist = "/Library/LaunchDaemons/com.hypervibe.hcihelper.plist"
    static let socketPath = "/var/run/com.hypervibe.hci.sock"
    /// Root-owned session root; helper creates per-capture subdirs here.
    static let sessionRoot = "/var/tmp/com.hypervibe.hci"
    static let bundledHelperRelativePath = "Helpers/com.hypervibe.hcihelper"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperBinary)
            && FileManager.default.fileExists(atPath: launchdPlist)
    }

    static var socketExists: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    static func bundledHelperURL(in bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let url = resources.appendingPathComponent(bundledHelperRelativePath)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

enum HCIHelperRequest: Equatable {
    case ping
    case status
    case stop
    /// Client supplies only PacketLogger path + parent PID. Session paths are
    /// created by the helper under `HCIHelperPaths.sessionRoot`.
    case start(packetLoggerPath: String, parentPID: Int32)
}

enum HCIHelperResponse: Equatable {
    case ok
    case pong
    case status(String)
    /// Successful START — client tails `outputPath` and may delete `tokenPath` to stop.
    case started(outputPath: String, tokenPath: String)
    case error(String)
}

enum HCIHelperCodec {
    static func encode(_ request: HCIHelperRequest) -> String {
        switch request {
        case .ping:
            return "PING\n"
        case .status:
            return "STATUS\n"
        case .stop:
            return "STOP\n"
        case let .start(packetLoggerPath, parentPID):
            let fields = [
                "START",
                escape(packetLoggerPath),
                String(parentPID),
            ]
            return fields.joined(separator: "|") + "\n"
        }
    }

    static func decodeRequest(_ line: String) -> HCIHelperRequest? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        if trimmed == "PING" { return .ping }
        if trimmed == "STATUS" { return .status }
        if trimmed == "STOP" { return .stop }
        guard trimmed.hasPrefix("START|") else { return nil }
        let parts = splitFields(trimmed)
        guard parts.count == 3, parts[0] == "START", let pid = Int32(parts[2]) else { return nil }
        return .start(
            packetLoggerPath: unescape(parts[1]),
            parentPID: pid
        )
    }

    static func encodeResponse(_ response: HCIHelperResponse) -> String {
        switch response {
        case .ok:
            return "OK\n"
        case .pong:
            return "PONG\n"
        case .status(let value):
            return "STATUS|\(escape(value))\n"
        case let .started(outputPath, tokenPath):
            return "STARTED|\(escape(outputPath))|\(escape(tokenPath))\n"
        case .error(let message):
            return "ERR|\(escape(message))\n"
        }
    }

    static func decodeResponse(_ line: String) -> HCIHelperResponse? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        if trimmed == "OK" { return .ok }
        if trimmed == "PONG" { return .pong }
        if trimmed.hasPrefix("STARTED|") {
            let parts = splitFields(trimmed)
            guard parts.count >= 3 else { return nil }
            return .started(outputPath: unescape(parts[1]), tokenPath: unescape(parts[2]))
        }
        if trimmed.hasPrefix("STATUS|") {
            let parts = splitFields(trimmed)
            guard parts.count >= 2 else { return nil }
            return .status(unescape(parts[1]))
        }
        if trimmed.hasPrefix("ERR|") {
            let parts = splitFields(trimmed)
            guard parts.count >= 2 else { return nil }
            return .error(unescape(parts.dropFirst().joined(separator: "|")))
        }
        return nil
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                guard let next = iterator.next() else {
                    result.append("\\")
                    break
                }
                switch next {
                case "\\": result.append("\\")
                case "|": result.append("|")
                case "n": result.append("\n")
                default:
                    result.append("\\")
                    result.append(next)
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private static func splitFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                current.append(ch)
                if let next = iterator.next() {
                    current.append(next)
                }
            } else if ch == "|" {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }
}

enum HCIHelperPathValidation {
    /// Only allow PacketLogger binaries packaged inside an `.app` bundle.
    static func isAllowedPacketLoggerPath(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: resolved) else { return false }
        guard resolved.hasSuffix("/Contents/Resources/packetlogger") else { return false }
        return resolved.contains(".app/")
    }
}

enum HCIHelperInstall {
    static func makeLaunchdPlist(
        label: String,
        helperPath: String,
        socketPath: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperPath)</string>
                <string>--socket</string>
                <string>\(socketPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/var/log/com.hypervibe.hcihelper.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/com.hypervibe.hcihelper.log</string>
        </dict>
        </plist>
        """
    }

    static func makeInstallScript(
        helperSourcePath: String,
        helperInstallPath: String = HCIHelperPaths.helperBinary,
        plistPath: String = HCIHelperPaths.launchdPlist,
        label: String = HCIHelperPaths.launchdLabel,
        socketPath: String = HCIHelperPaths.socketPath
    ) -> String {
        let src = ShellQuote.single(helperSourcePath)
        let dst = ShellQuote.single(helperInstallPath)
        let plist = ShellQuote.single(plistPath)
        let sessionRoot = ShellQuote.single(HCIHelperPaths.sessionRoot)
        let plistBody = makeLaunchdPlist(
            label: label,
            helperPath: helperInstallPath,
            socketPath: socketPath
        )
        return """
        #!/bin/sh
        set -e
        umask 022
        mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons \(sessionRoot)
        chown root:wheel \(sessionRoot)
        chmod 755 \(sessionRoot)
        cp \(src) \(dst)
        chown root:wheel \(dst)
        chmod 755 \(dst)
        cat > \(plist) <<'PLIST'
        \(plistBody)
        PLIST
        chown root:wheel \(plist)
        chmod 644 \(plist)
        launchctl bootout system/\(label) >/dev/null 2>&1 || true
        launchctl bootstrap system \(plist)
        launchctl enable system/\(label) >/dev/null 2>&1 || true
        launchctl kickstart -k system/\(label)
        """
    }

    static func makeUninstallScript(
        helperInstallPath: String = HCIHelperPaths.helperBinary,
        plistPath: String = HCIHelperPaths.launchdPlist,
        label: String = HCIHelperPaths.launchdLabel,
        socketPath: String = HCIHelperPaths.socketPath
    ) -> String {
        """
        #!/bin/sh
        set -u
        launchctl bootout system/\(label) >/dev/null 2>&1 || true
        rm -f \(ShellQuote.single(plistPath))
        rm -f \(ShellQuote.single(helperInstallPath))
        rm -f \(ShellQuote.single(socketPath))
        rm -rf \(ShellQuote.single(HCIHelperPaths.sessionRoot))
        """
    }
}
