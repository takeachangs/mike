// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Listen",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7")],
    targets: [.executableTarget(name: "Listen", dependencies: ["FluidAudio"])],
    swiftLanguageModes: [.v5]
)
