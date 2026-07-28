// swift-tools-version: 5.9
// NOTE: This package does not include MultitouchSupport.framework (private API).
// Use build.sh for full trackpad + FluidAudio Parakeet support.

import PackageDescription

let package = Package(
    name: "HyperVibe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HyperVibe", targets: ["HyperVibe"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "HyperVibe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: ".",
            sources: [
                "main.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "RemoteDetector.swift",
                "RemoteInputHandler.swift",
                "CursorController.swift",
                "MediaController.swift",
                "MediaKeyInterceptor.swift",
                "TouchHandler.swift",
                "SystemVolume.swift",
                "OpusVoiceDecoder.swift",
                "HCICaptureBootstrap.swift",
                "MicActivator.swift",
                "MicCapturePipeline.swift",
                "RemoteMicController.swift",
                "RemoteMicLab.swift",
                "TranscriptionEngine.swift",
                "TranscriptionKeychain.swift",
                "OpenAITranscriptionEngine.swift",
                "ParakeetTranscriptionEngine.swift",
                "HCIHelperProtocol.swift",
                "HCIHelperClient.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Security"),
                .linkedLibrary("opus"),
                .linkedLibrary("c++")
            ]
        )
    ]
)
