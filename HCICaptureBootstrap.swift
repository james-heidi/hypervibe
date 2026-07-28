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
