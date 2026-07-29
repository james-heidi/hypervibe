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
                "ButtonActions.swift",
                "PermissionState.swift",
                "SetupFlow.swift",
                "OnboardingWindowController.swift",
                "HelperInstallCoordinator.swift",
                "ButtonMappingStore.swift",
                "RemoteAdapter.swift",
                "MappingProfileStore.swift",
                "DictationRecovery.swift",
                "WaveGlyph.swift",
                "ModelPreparation.swift",
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
                "MicReadinessState.swift",
                "RemoteMicController.swift",
                "RemoteMicLab.swift",
                "TranscriptionEngine.swift",
                "AudioFrontEnd.swift",
                "VocabularyStore.swift",
                "CorpusRecorder.swift",
                "TranscriptionKeychain.swift",
                "OpenAITranscriptionEngine.swift",
                "ParakeetTranscriptionEngine.swift",
                "TranscriptPolisher.swift",
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
