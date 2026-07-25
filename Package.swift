// swift-tools-version: 5.9
// NOTE: This package does not include MultitouchSupport.framework (private API).
// Use build.sh for full trackpad support.

import PackageDescription

let package = Package(
    name: "HyperVibe",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "HyperVibe", targets: ["HyperVibe"])
    ],
    targets: [
        .executableTarget(
            name: "HyperVibe",
            path: ".",
            sources: [
                "main.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "RemoteDetector.swift",
                "RemoteInputHandler.swift",
                "RemoteWebServer.swift",
                "CursorController.swift",
                "MediaController.swift",
                "MediaKeyInterceptor.swift",
                "TouchHandler.swift",
                "SystemVolume.swift",
                "OpusVoiceDecoder.swift",
                "BlackHoleAudioSink.swift",
                "MicActivator.swift",
                "MicCapturePipeline.swift",
                "RemoteMicController.swift",
                "RemoteMicLab.swift",
                "HCIEventTap.swift",
                "DurableCaptureSpike.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOBluetooth"),
                .linkedLibrary("opus")
            ]
        )
    ]
)
