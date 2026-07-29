// swift-tools-version: 5.9
// Offline eval CLI. Pins the SAME FluidAudio version as the app
// (Vendor/FluidAudioDeps/Package.swift) so baseline numbers are honest.

import PackageDescription

let package = Package(
    name: "ParakeetEvalCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "parakeet-eval",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources"
        )
    ]
)
