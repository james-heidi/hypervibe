//
//  HyperVibeHCIHelperMain.swift
//  HyperVibeHCIHelper
//
//  Root LaunchDaemon: one admin install, then local socket start/stop of PacketLogger.
//

import Foundation

@main
struct HyperVibeHCIHelperMain {
    static func main() {
        var socketPath = HCIHelperPaths.socketPath
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--socket"), args.count > idx + 1 {
            socketPath = args[idx + 1]
        }
        do {
            try HCIHelperServer(socketPath: socketPath).run()
        } catch {
            fputs("HyperVibeHCIHelper failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
