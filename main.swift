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
    print("PacketLogger:", MicCapturePipeline.packetLoggerURL()?.path ?? "MISSING")
    print("Bluetooth profile installed:", MicCapturePipeline.bluetoothProfileInstalled())
    print("Remote address:", MicCapturePipeline.detectRemoteAddress() ?? "MISSING")
    let sink = BlackHoleAudioSink()
    print("BlackHole available:", sink.isAvailable)
    print("Opus decoder:", OpusVoiceDecoder() != nil ? "ok" : "FAILED")
    exit(0)
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
        try? RemoteMicController.writeWAV(
            samples: pcm,
            sampleRate: Int(OpusVoiceDecoder.sampleRate),
            to: URL(fileURLWithPath: "/tmp/hypervibe-opus-test.wav")
        )
        print("wrote /tmp/hypervibe-opus-test.wav")
    }
    exit(pcm.isEmpty ? 1 : 0)
}

if args.contains("--test-blackhole") {
    let sink = BlackHoleAudioSink()
    guard sink.start() else {
        print("BlackHole start failed — install blackhole-2ch and reboot")
        exit(1)
    }
    // 440 Hz tone for 1 second
    let sr = Int(OpusVoiceDecoder.sampleRate)
    var samples = [Int16](repeating: 0, count: sr)
    let freq = 440.0
    for i in 0..<sr {
        let t = Double(i) / Double(sr)
        samples[i] = Int16(sin(2 * Double.pi * freq * t) * Double(Int16.max / 4))
    }
    sink.enqueue(pcmS16: samples)
    Thread.sleep(forTimeInterval: 1.2)
    sink.stop()
    print("played 440 Hz into \(sink.deviceName ?? "?")")
    exit(0)
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
        try? RemoteMicController.writeWAV(
            samples: samples,
            sampleRate: Int(OpusVoiceDecoder.sampleRate),
            to: URL(fileURLWithPath: "/tmp/hypervibe-replay.wav")
        )
        print("wrote /tmp/hypervibe-replay.wav")
    }
    exit(capture.framesSeen > 0 ? 0 : 1)
}

if args.contains("--activate-mic") {
    let tap = HCIEventTap()
    tap.start()
    let activator = MicActivator()
    print("Arming MicActivator (0xAF + PushToTalk) + HCIEventTap…")
    activator.arm()
    print("Hold Siri and speak for 10s (RunLoop spinning for callbacks)…")
    let deadline = Date().addingTimeInterval(10)
    var rearmed = false
    while Date() < deadline {
        if !rearmed, Date().timeIntervalSince(deadline.addingTimeInterval(-10)) > 2 {
            activator.rearmOnSiriDown()
            rearmed = true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    activator.disarm()
    tap.stop()
    print("done — HCI events=\(tap.eventCount); see /tmp/hypervibe.log")
    exit(0)
}

// Create the application instance
let app = NSApplication.shared

// Create and set the delegate
let delegate = AppDelegate()
app.delegate = delegate

// Run the application
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
