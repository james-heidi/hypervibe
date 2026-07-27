// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FluidAudioDeps",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FluidAudio", targets: ["FluidAudioExport"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .target(
            name: "FluidAudioExport",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources"
        )
    ]
)
