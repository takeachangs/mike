// swift-tools-version: 6.0
import PackageDescription

// CallNotch: the notch app, the Listen recorder CLI (used by the /listen skill), and the library both are built on.
let package = Package(
    name: "CallNotch",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7")],
    targets: [
        .target(name: "CallNotchKit", dependencies: ["FluidAudio"], resources: [.copy("Resources/sounds")]),
        .executableTarget(name: "CallNotch", dependencies: ["CallNotchKit"]),
        .executableTarget(name: "Listen", dependencies: ["CallNotchKit"]),
        .testTarget(name: "CallNotchKitTests", dependencies: ["CallNotchKit"]),
    ],
    swiftLanguageModes: [.v5]
)
