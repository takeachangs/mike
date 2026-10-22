// swift-tools-version: 6.0
import PackageDescription

// Mike: the notch app, the Listen recorder CLI (used by the /listen skill), and the library both are built on.
let package = Package(
    name: "Mike",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7")],
    targets: [
        .target(name: "MikeKit", dependencies: ["FluidAudio"], resources: [.copy("Resources/sounds")]),
        .executableTarget(name: "Mike", dependencies: ["MikeKit"]),
        .executableTarget(name: "Listen", dependencies: ["MikeKit"]),
        .testTarget(name: "MikeKitTests", dependencies: ["MikeKit"]),
    ],
    swiftLanguageModes: [.v5]
)
