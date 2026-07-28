//
//  main.swift
//  HyperVibe
//
//  Application entry point
//

import AppKit
import Foundation

let args = CommandLine.arguments
if args.contains("--mic-check") {
    let r = RemoteMicLab.evaluate()
    print("Remote dictation ready:", r.isReady)
    print("PacketLogger:", MicCapturePipeline.packetLoggerURL()?.path ?? "MISSING")
    print("HCI helper installed:", HCIHelperPaths.isInstalled)
    print("HCI helper ready:", HCIHelperClient.isReady())
    print("Remote address:", r.remoteAddress ?? "MISSING")
    print("Opus decoder:", OpusVoiceDecoder() != nil ? "ok" : "FAILED")
    print("---")
    print(r.checklistText)
    exit(r.isReady ? 0 : 1)
}

if args.contains("--test-opus") {
    // Synthetic A2854-shaped silence frame is not valid Opus; decode a minimal CELT WB
    // packet only if a hex fixture path is provided.
    guard let idx = args.firstIndex(of: "--test-opus"),
          args.count > idx + 1 else {
        print("usage: HyperVibe --test-opus <hex-payload-file>")
        exit(2)
    }
    let text = (try? String(contentsOfFile: args[idx + 1], encoding: .utf8)) ?? ""
    let hex = text.filter { $0.isHexDigit }
    var bytes = [UInt8]()
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        if let b = UInt8(hex[i..<j], radix: 16) { bytes.append(b) }
        i = j
    }
    guard let decoder = OpusVoiceDecoder() else {
        print("decoder create failed")
        exit(1)
    }
    let pcm = decoder.feed(Data(bytes))
    print("parsed=\(OpusVoiceDecoder.parsePacket(Data(bytes)) != nil) samples=\(pcm.count)")
    if !pcm.isEmpty {
        try? PCMWaveWriter.write(
            samples: pcm,
            sampleRate: Int(OpusVoiceDecoder.sampleRate),
            to: URL(fileURLWithPath: "/tmp/hypervibe-opus-test.wav")
        )
        print("wrote /tmp/hypervibe-opus-test.wav")
    }
    exit(pcm.isEmpty ? 1 : 0)
}

if args.contains("--capture-mic") {
    let rest = Array(args.drop(while: { $0 != "--capture-mic" }).dropFirst())
    let seconds = Double(rest.first ?? "15") ?? 15
    let mic = RemoteMicController()
    mic.setEnabled(true)
    mic.startIdleCaptureIfEnabled()
    print("Capturing for \(seconds)s — hold Siri and speak…")
    // Simulate continuous arm so frames are accepted even if HID callback isn't wired in CLI.
    mic.handleSiri(pressed: true)
    Thread.sleep(forTimeInterval: seconds)
    mic.handleSiri(pressed: false)
    mic.shutdown()
    print("done — check /tmp/hypervibe.log and /tmp/hypervibe-remote-mic.wav")
    exit(0)
}

if args.contains("--replay-hci") {
    guard let idx = args.firstIndex(of: "--replay-hci"),
          args.count > idx + 1 else {
        print("usage: HyperVibe --replay-hci <nhdr-text-file>")
        exit(2)
    }
    let path = args[idx + 1]
    let capture = MicCapturePipeline()
    guard let decoder = OpusVoiceDecoder() else {
        print("decoder failed")
        exit(1)
    }
    var samples = [Int16]()
    let sem = DispatchSemaphore(value: 0)
    capture.onPayload = { payload in
        samples.append(contentsOf: decoder.feed(payload))
    }
    capture.onStatus = { status in
        print("status:", status.menuLabel)
        if case .error = status { sem.signal() }
        if case .streaming = status { /* keep going */ }
    }
    capture.startReplaying(fileAt: path)
    // Allow async replay to finish
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { sem.signal() }
    sem.wait()
    print("frames=\(capture.framesSeen) samples=\(samples.count)")
    if !samples.isEmpty {
        try? PCMWaveWriter.write(
            samples: samples,
            sampleRate: Int(OpusVoiceDecoder.sampleRate),
            to: URL(fileURLWithPath: "/tmp/hypervibe-replay.wav")
        )
        print("wrote /tmp/hypervibe-replay.wav")
    }
    exit(capture.framesSeen > 0 ? 0 : 1)
}

// Create the application instance
let app = NSApplication.shared

// Create and set the delegate
let delegate = AppDelegate()
app.delegate = delegate

// Run the application
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
