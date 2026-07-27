//
//  HCICaptureBootstrap.swift
//  HyperVibe
//
//  Pure helpers for locating a bundled PacketLogger and generating the short-lived
//  privileged capture script. Kept Foundation-only so it can be tested standalone.
//

import Foundation

enum PacketLoggerLocator {
    static func firstExecutable(
        candidates: [String],
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) -> String? {
        candidates.first(where: isExecutable)
    }
}

enum ShellQuote {
    static func single(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

struct PrivilegedHCICaptureConfig {
    let packetLoggerPath: String
    let sessionDirectoryPath: String
    let outputPath: String
    let tokenPath: String
    let parentPID: Int32
}

enum PrivilegedHCICaptureScript {
    static func make(_ config: PrivilegedHCICaptureConfig) -> String {
        let logger = ShellQuote.single(config.packetLoggerPath)
        let sessionDirectory = ShellQuote.single(config.sessionDirectoryPath)
        let output = ShellQuote.single(config.outputPath)
        let token = ShellQuote.single(config.tokenPath)
        let backup = ShellQuote.single(config.outputPath + ".preferences.plist")

        return """
        #!/bin/sh
        set -u
        umask 022

        PREF_DOMAIN=/Library/Preferences/com.apple.MobileBluetooth.debug
        PREF_FILE="${PREF_DOMAIN}.plist"
        PREF_BACKUP=\(backup)
        SESSION_DIR=\(sessionDirectory)
        OUTPUT=\(output)
        TOKEN=\(token)
        PARENT_PID=\(config.parentPID)
        HAD_PREFS=0
        CAPTURE_PID=""

        cleanup() {
          status=$?
          trap - EXIT INT TERM
          if test -n "$CAPTURE_PID"; then
            kill -INT "$CAPTURE_PID" 2>/dev/null || true
            wait "$CAPTURE_PID" 2>/dev/null || true
          fi
          if test "$HAD_PREFS" = "1"; then
            defaults import "$PREF_DOMAIN" "$PREF_BACKUP" >/dev/null 2>&1 || true
          else
            defaults delete "$PREF_DOMAIN" >/dev/null 2>&1 || true
            rm -f "$PREF_FILE"
          fi
          rm -f "$PREF_BACKUP"
          killall -30 bluetoothd 2>/dev/null || true
          rm -rf "$SESSION_DIR"
          exit "$status"
        }
        trap cleanup EXIT INT TERM

        rm -f "$PREF_BACKUP"
        if test -f "$PREF_FILE"; then
          defaults export "$PREF_DOMAIN" "$PREF_BACKUP" >/dev/null 2>&1 && HAD_PREFS=1
        fi

        defaults write "$PREF_DOMAIN" HCITraces -dict \
          StackDebugEnabled -bool true \
          HCILiveTraces -bool true \
          HCIFileTraces -bool true \
          RawAudioTrace -bool true \
          HIDTrace -bool true \
          HCISkipAuth -bool true

        killall -30 bluetoothd 2>/dev/null || true
        sleep 2

        : > "$OUTPUT"
        chmod 0644 "$OUTPUT"
        \(logger) convert -s -f nhdr > "$OUTPUT" 2>&1 &
        CAPTURE_PID=$!

        while kill -0 "$PARENT_PID" 2>/dev/null \
          && test -e "$TOKEN" \
          && kill -0 "$CAPTURE_PID" 2>/dev/null
        do
          sleep 1
        done
        """
    }
}
